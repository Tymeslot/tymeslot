defmodule TymeslotWeb.Dashboard.CalendarMessages do
  @moduledoc """
  The calendar's share of `TymeslotWeb.DashboardLive`'s mailbox: sync and
  event-change broadcasts, write and delete results, booking moves, and
  create and import results.

  Each message goes to the module that acts on it, mostly
  `TymeslotWeb.Dashboard.CalendarEventHandlers`,
  `TymeslotWeb.Dashboard.CalendarRouting` and, for an `.ics` import,
  `TymeslotWeb.Dashboard.IcsImportRunner`. Meeting mode's round trip and
  guest RSVPs are the calendar's too.
  `handle_info/2` answers what a LiveView's `handle_info/2` would, or
  `:unhandled` for a message that is not the calendar's, so `DashboardLive`
  keeps one clause for the whole calendar.

  A result that can add, move or remove an event also rebuilds the agenda
  (`AgendaRefresh.refresh/1`): the overview and the Up next strip above the
  calendar run their own query, so without it they kept showing a deleted
  event for up to a minute. The rebuild is a no-op where no agenda is shown.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias TymeslotWeb.Dashboard.AgendaRefresh
  alias TymeslotWeb.Dashboard.BookingsManagement.CalendarMove
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.CalendarEventHandlers
  alias TymeslotWeb.Dashboard.CalendarRouting
  alias TymeslotWeb.Dashboard.IcsImportRunner

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Acts on a calendar message, or answers `:unhandled` for any other.
  """
  @spec handle_info(term(), socket()) :: {:noreply, socket()} | :unhandled
  # A guest answered an invitation (`Tymeslot.Meetings.Guests`): the
  # calendar on screen refreshes the RSVP state it shows.
  def handle_info({:guest_rsvp_updated, _meeting_id}, socket) do
    CalendarRouting.to_mounted(socket, action: :refresh_guest_summaries)
    {:noreply, socket}
  end

  def handle_info({:calendar_events_updated, _user_id, _changed_uids}, socket),
    do: socket |> CalendarEventHandlers.handle_calendar_events_updated() |> rebuild_agenda()

  def handle_info({:calendar_sync_complete, _user_id, integration_id}, socket),
    do: CalendarEventHandlers.handle_calendar_sync_complete(socket, integration_id)

  def handle_info({:calendar_sync_failed, _user_id, integration_id}, socket),
    do: CalendarEventHandlers.handle_calendar_sync_failed(socket, integration_id)

  # `Tymeslot.Availability.changed/1` broadcasts on the organiser's topic
  # (subscribed by `DashboardLive` on the calendar page).
  def handle_info({:availability_changed, _user_id}, socket) do
    CalendarRouting.bookable_changed(socket)
    {:noreply, socket}
  end

  # A scheduled delete ran (`Tymeslot.CalendarGrid.ScheduledDelete`), having
  # removed the cached row first, so the agenda can drop the event now.
  def handle_info({:calendar_delete_result, _user_id, token, outcome}, socket),
    do:
      socket
      |> CalendarEventHandlers.handle_calendar_delete_result(token, outcome)
      |> rebuild_agenda()

  def handle_info({:calendar_delete_scheduled, _user_id, token, address, scope}, socket) do
    CalendarRouting.delete_scheduled(socket, token, address, scope)
    {:noreply, socket}
  end

  def handle_info({:calendar_delete_cancelled, _user_id, token}, socket) do
    CalendarRouting.delete_cancelled(socket, token)
    {:noreply, socket}
  end

  # A create the calendar surface started (`Tymeslot.CalendarGrid.WriteTask`)
  # finished: its draft is settled on the surface if it is still on screen,
  # and otherwise (the organiser left the calendar) the outcome is flashed
  # here, so it is never lost.
  def handle_info({:calendar_create_result, {draft_id, title}, result}, socket) do
    socket =
      case CalendarRouting.create_settled(socket, draft_id, title, result) do
        :ok ->
          socket

        :off_screen ->
          Enum.reduce(
            [Creation.outcome_message(title, result) | Creation.notices(result)],
            socket,
            fn {kind, message}, acc -> put_flash(acc, kind, message) end
          )
      end

    rebuild_agenda({:noreply, socket})
  end

  # A booking move the calendar's preview started
  # (`TymeslotWeb.Dashboard.Calendar.BookingMove`) finished: settled on the
  # surface if it is on screen, and otherwise flashed here.
  def handle_info({:booking_move_result, meeting_id, result}, socket) do
    case CalendarRouting.booking_move_settled(socket, meeting_id, result) do
      :ok -> :ok
      :off_screen -> _outcome = CalendarMove.announce(socket, meeting_id, result)
    end

    rebuild_agenda({:noreply, socket})
  end

  def handle_info({:event_update_result, result}, socket),
    do: result |> CalendarEventHandlers.handle_event_update_result(socket) |> rebuild_agenda()

  def handle_info({:event_move_result, result}, socket),
    do: result |> CalendarEventHandlers.handle_event_move_result(socket) |> rebuild_agenda()

  def handle_info({:event_video_result, result}, socket),
    do: CalendarEventHandlers.handle_event_video_result(result, socket)

  def handle_info({:event_writes_released, release}, socket),
    do: CalendarEventHandlers.handle_event_writes_released(release, socket)

  def handle_info({:execute_create_ad_hoc_meeting, request, params}, socket),
    do: CalendarEventHandlers.handle_execute_create_ad_hoc_meeting(request, params, socket)

  def handle_info({:create_ad_hoc_meeting_result, request, result}, socket),
    do:
      request
      |> CalendarEventHandlers.handle_create_ad_hoc_meeting_result(result, socket)
      |> rebuild_agenda()

  def handle_info({:execute_ics_import, payload}, socket),
    do: IcsImportRunner.execute(payload, socket)

  def handle_info({:ics_import_progress, done}, socket),
    do: IcsImportRunner.progress(done, socket)

  def handle_info({:ics_import_result, result}, socket),
    do: IcsImportRunner.result(result, socket)

  def handle_info(_message, _socket), do: :unhandled

  defp rebuild_agenda({:noreply, socket}), do: {:noreply, AgendaRefresh.refresh(socket)}
end
