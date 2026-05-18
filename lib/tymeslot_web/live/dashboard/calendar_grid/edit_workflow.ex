defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow do
  @moduledoc "Drag, resize, create, and inline-edit workflow orchestration for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Updates
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec default_integration_id(Phoenix.LiveView.Socket.t()) :: integer() | nil
  def default_integration_id(socket) do
    case socket.assigns.integrations do
      [first | _rest] -> first.id
      [] -> nil
    end
  end

  @spec default_calendar_id(list(), integer() | nil) :: String.t() | nil
  def default_calendar_id(_integrations, nil), do: nil

  def default_calendar_id(integrations, integration_id) do
    case Enum.find(integrations, &(&1.id == integration_id)) do
      nil -> nil
      integration -> default_calendar_id_for(integration)
    end
  end

  @spec default_calendar_id_for(map()) :: String.t() | nil
  def default_calendar_id_for(integration) do
    integration.default_booking_calendar_id ||
      find_primary_calendar_id(integration.calendar_list)
  end

  defp find_primary_calendar_id(nil), do: nil
  defp find_primary_calendar_id([]), do: nil

  defp find_primary_calendar_id(calendar_list) do
    primary = Enum.find(calendar_list, &(&1["primary"] || &1[:primary]))
    selected = primary || Enum.find(calendar_list, &(&1["selected"] || &1[:selected]))
    cal = selected || List.first(calendar_list)
    cal["id"] || cal[:id]
  end

  @spec format_create_time(map()) :: String.t()
  def format_create_time(creating) do
    "#{format_time_value(creating.start_hour, creating.start_minute)} – #{format_time_value(creating.end_hour, creating.end_minute)}"
  end

  @spec format_time_value(integer(), integer()) :: String.t()
  def format_time_value(hour, minute) do
    "#{String.pad_leading("#{hour}", 2, "0")}:#{String.pad_leading("#{minute}", 2, "0")}"
  end

  @spec with_editable_event(Phoenix.LiveView.Socket.t(), map(), function()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def with_editable_event(socket, params, fun) do
    case Integer.parse(params["event-id"] || "") do
      {event_id, ""} ->
        event = Enum.find(socket.assigns.events, &(&1.id == event_id))

        cond do
          is_nil(event) ->
            {:noreply, socket}

          assert_owns_event(socket, event) == {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          true ->
            {:noreply, fun.(event)}
        end

      _invalid ->
        {:noreply, socket}
    end
  end

  @spec apply_event_change(Phoenix.LiveView.Socket.t(), map(), map(), DateTime.t(), DateTime.t()) ::
          Phoenix.LiveView.Socket.t()
  def apply_event_change(socket, event, optimistic_event, new_start, new_end) do
    original_events = socket.assigns.events

    new_events =
      Enum.map(original_events, fn e ->
        if e.id == event.id, do: optimistic_event, else: e
      end)

    socket =
      socket
      |> assign(:events, new_events)
      |> Helpers.precompute_derived()

    if event.recurring_event_id do
      prompt = %{
        event: event,
        optimistic_event: optimistic_event,
        new_start: new_start,
        new_end: new_end,
        original_event: event
      }

      assign(socket, :recurrence_prompt, prompt)
    else
      Updates.update_event_async(socket, event, optimistic_event, new_start, new_end)
    end
  end

  @spec assert_owns_event(Phoenix.LiveView.Socket.t(), map()) :: :ok | {:error, :unauthorized}
  def assert_owns_event(socket, event) do
    if MapSet.member?(socket.assigns.owned_integration_ids, event.calendar_integration_id) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Routes an event edit through `Tymeslot.Meetings.AttendeeNotifications`.

  Returns one of:

    * `{:ok, :no_changes}` — nothing notifiable changed, or the event has no
      attendees. Caller should flash "Changes saved."
    * `{:ok, :already_pending}` — changes were notifiable, but a Worker job is
      already queued inside the debounce window. This call re-confirmed into
      the existing job (replacing `scheduled_at`). Caller should flash
      "Changes saved. Attendees will be notified shortly."
    * `{:needs_confirmation, ChangeSummary.t}` — notifiable changes, nothing
      pending. Caller should stash the summary and show the confirmation modal.
  """
  @spec notify_event_updated(map(), map(), [map()]) ::
          {:ok, :no_changes}
          | {:ok, :already_pending}
          | {:needs_confirmation, ChangeSummary.t()}
  def notify_event_updated(original_event, updated_event, attendees) do
    case AttendeeNotifications.event_updated(original_event, updated_event, attendees) do
      {:ok, :no_changes} ->
        {:ok, :no_changes}

      {:needs_confirmation, summary} ->
        if AttendeeNotifications.pending?(updated_event.id) do
          {:ok, :sent} =
            AttendeeNotifications.event_updated_confirm(updated_event, summary, attendees)

          {:ok, :already_pending}
        else
          {:needs_confirmation, summary}
        end
    end
  end
end
