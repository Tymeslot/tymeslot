defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.SeriesMove do
  @moduledoc """
  Moving a whole recurring series to another calendar from the detail modal.

  Choosing another calendar for a member of a series whose provider can move
  a series (`Tymeslot.CalendarGrid.ensure_movable/1` answers `{:ok,
  :series}`) moves every event in it, so the organiser confirms it first in
  `ConfirmSeriesMoveModal`, which also says what the move will not carry
  (`Tymeslot.CalendarGrid.series_move_notes/2`). A move the series cannot
  make is refused there and then, without the modal.

  Nothing on the grid changes until the move has answered: the series is
  not shown on its new calendar while it moves, and cancelling changes
  nothing at all. A series with a change of one of its events still saving
  is not moved until that change has saved, since the move copies the
  series as it was before it. The result is handled with every other move's, in
  `TymeslotWeb.Dashboard.CalendarEventHandlers.handle_event_move_result/2`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.EventWrites

  @doc """
  Asks the organiser to confirm moving the series `event` belongs to onto
  `calendar_id` of the integration `integration_id` (its default calendar
  when `nil`), or says why it cannot move there.
  """
  @spec prompt(Phoenix.LiveView.Socket.t(), map(), pos_integer(), String.t() | nil) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def prompt(socket, event, integration_id, calendar_id) do
    with %{} = integration <- Enum.find(socket.assigns.integrations, &(&1.id == integration_id)),
         {:ok, notes} <- CalendarGrid.series_move_notes(event, integration) do
      prompt = %{
        event: event,
        integration: integration,
        calendar_id: calendar_id,
        calendar_name: calendar_name(integration, calendar_id),
        notes: notes
      }

      {:noreply, assign(socket, :series_move_prompt, prompt)}
    else
      nil ->
        {:noreply, socket}

      {:error, reason} ->
        send(self(), {:flash, {:error, EditWorkflow.series_move_failed_message(reason)}})
        {:noreply, socket}
    end
  end

  @spec handle_confirm_series_move(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_series_move(_params, socket) do
    case socket.assigns.series_move_prompt do
      nil ->
        {:noreply, socket}

      prompt ->
        socket = assign(socket, :series_move_prompt, nil)

        with false <- EventWrites.series_saving?(socket, prompt.event),
             :ok <- Shared.check_move_rate_limit(socket) do
          send(self(), {:flash, {:info, moving_message(prompt.calendar_name)}})

          {:noreply,
           EditWorkflow.move_event_async(
             socket,
             prompt.event,
             prompt.integration,
             prompt.calendar_id,
             series_to: prompt.calendar_name
           )}
        else
          true ->
            send(self(), {:flash, {:warning, still_saving_message()}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, EditWorkflow.move_rate_limited_message()}})
            {:noreply, socket}
        end
    end
  end

  @spec handle_cancel_series_move(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_series_move(_params, socket),
    do: {:noreply, assign(socket, :series_move_prompt, nil)}

  # The calendar as the picker names it, or the integration's own name for
  # one with no calendar list of its own.
  defp calendar_name(integration, calendar_id) do
    calendar_id = calendar_id || EditWorkflow.default_calendar_id_for(integration)

    calendars = Calendar.writable_calendars(integration.calendar_list)

    case Enum.find(calendars, &(&1.id == calendar_id)) do
      nil -> integration.name
      calendar -> DisplayHelpers.extract_calendar_display_name(calendar)
    end
  end

  defp still_saving_message do
    dgettext(
      "dashboard_calendar_events",
      "A change to this series is still saving. Please move the series once it has saved."
    )
  end

  defp moving_message(calendar) do
    dgettext("dashboard_calendar_events", "Moving the series to %{calendar}...",
      calendar: calendar
    )
  end
end
