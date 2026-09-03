defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow do
  @moduledoc "Drag, resize, create, and inline-edit workflow orchestration for CalendarGridComponent."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Updates
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
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

  @doc """
  Resolves the calendar to pre-select for `integration`, restricted to the
  same subset `CalendarPicker` renders as chips (`Calendar.writable_calendars/1`
  — selected and not read-only). Resolving against a wider set here than the
  picker offers would default to a calendar the user is never shown, and the
  event would be created there with no chip highlighted to explain it.
  """
  @spec default_calendar_id_for(map()) :: String.t() | nil
  def default_calendar_id_for(integration) do
    booking_id = Map.get(integration, :default_booking_calendar_id)
    calendars = Calendar.writable_calendars(integration.calendar_list)

    case Calendar.default_booking_calendar(calendars, booking_id) do
      nil -> nil
      entry -> entry.id
    end
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
        case Enum.find(socket.assigns.events, &(&1.id == event_id)) do
          nil -> {:noreply, socket}
          event -> with_editable_event_found(socket, event, fun)
        end

      _invalid ->
        {:noreply, socket}
    end
  end

  defp with_editable_event_found(socket, event, fun) do
    case assert_event_writable(socket, event) do
      :ok -> {:noreply, fun.(event)}
      {:error, _reason} = error -> Shared.flash_guard_error(socket, error)
    end
  end

  @spec apply_event_change(Phoenix.LiveView.Socket.t(), map(), map(), DateTime.t(), DateTime.t()) ::
          Phoenix.LiveView.Socket.t()
  def apply_event_change(socket, event, optimistic_event, new_start, new_end) do
    new_events = Shared.replace_event(socket.assigns.events, event.id, optimistic_event)

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
    assert_owns_integration(socket, event.calendar_integration_id)
  end

  @doc """
  The gate every write to an existing grid event goes through: the organiser
  must own the integration *and* the calendar the event sits on must accept
  writes.

  Ownership alone is not enough. A subscribed feed is the organiser's own
  integration, yet every provider write against it answers
  `{:error, :read_only}`; a Google calendar shared with `reader` access is
  likewise owned and unwritable. Refusing here is what keeps the failure a
  clear message instead of a provider round-trip that ends in "Failed to
  delete event".

  `event_editable?/2` is the same question asked of the assigns, and gates the
  affordance in the detail modal. The two must agree: this one is the
  authority, since a stale socket can still send the event.
  """
  @spec assert_event_writable(Phoenix.LiveView.Socket.t(), map()) ::
          :ok | {:error, :unauthorized} | {:error, :read_only}
  def assert_event_writable(socket, event) do
    with :ok <- assert_owns_event(socket, event) do
      if writable_event?(socket.assigns, event), do: :ok, else: {:error, :read_only}
    end
  end

  @doc """
  Whether the detail modal should offer edit and delete controls for `event`.

  Takes the assigns rather than the socket so templates can call it directly.
  """
  @spec event_editable?(map(), map()) :: boolean()
  def event_editable?(assigns, event) do
    MapSet.member?(assigns.owned_integration_ids, event.calendar_integration_id) and
      writable_event?(assigns, event)
  end

  # Resolves the event's integration from the loaded list — the same list
  # `owned_integration_ids` is built from, so an event whose integration is
  # missing here is one the organiser does not own.
  defp writable_event?(assigns, event) do
    case Enum.find(assigns.integrations, &(&1.id == event.calendar_integration_id)) do
      nil -> false
      integration -> Selection.event_writable?(event, integration)
    end
  end

  @spec assert_owns_integration(Phoenix.LiveView.Socket.t(), integer() | nil) ::
          :ok | {:error, :unauthorized}
  def assert_owns_integration(socket, integration_id) do
    if MapSet.member?(socket.assigns.owned_integration_ids, integration_id) do
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
