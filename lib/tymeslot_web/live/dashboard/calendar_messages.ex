defmodule TymeslotWeb.Dashboard.CalendarMessages do
  @moduledoc """
  The calendar's share of `TymeslotWeb.DashboardLive`'s mailbox: sync and
  event-change broadcasts, write and delete results, create and import
  results, and the old grid's timers.

  Each message goes to the module that acts on it, mostly
  `TymeslotWeb.Dashboard.CalendarEventHandlers` and
  `TymeslotWeb.Dashboard.CalendarRouting`. `handle_info/2` answers what a
  LiveView's `handle_info/2` would, or `:unhandled` for a message that is not
  the calendar's, so `DashboardLive` keeps one clause for the whole calendar.

  A result that can add, move or remove an event also rebuilds the agenda
  (`AgendaRefresh.refresh/1`): the overview and the old grid's Up-next strip
  run their own query, so without it they kept showing a deleted event for
  up to a minute. The rebuild is a no-op where no agenda is shown.
  """

  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias TymeslotWeb.Dashboard.AgendaRefresh
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.CalendarEventHandlers
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Dashboard.CalendarRouting
  alias TymeslotWeb.Dashboard.ComponentDispatch

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Acts on a calendar message, or answers `:unhandled` for any other.
  """
  @spec handle_info(term(), socket()) :: {:noreply, socket()} | :unhandled
  def handle_info({:guest_rsvp_updated, _meeting_id}, socket) do
    send_update(
      CalendarGridComponent,
      id: ComponentDispatch.component_id(:calendar),
      action: :refresh_guest_summaries
    )

    {:noreply, socket}
  end

  def handle_info(:tick, socket), do: CalendarEventHandlers.handle_tick(socket)

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

  def handle_info({:calendar_delete_result, _user_id, token, outcome}, socket),
    do: CalendarEventHandlers.handle_calendar_delete_result(socket, token, outcome)

  def handle_info({:calendar_delete_scheduled, _user_id, token, address, scope}, socket) do
    CalendarRouting.delete_scheduled(socket, token, address, scope)
    {:noreply, socket}
  end

  def handle_info({:calendar_delete_cancelled, _user_id, token}, socket) do
    CalendarRouting.delete_cancelled(socket, token)
    {:noreply, socket}
  end

  # A create the new surface started (`Tymeslot.CalendarGrid.WriteTask`)
  # finished: its draft is settled on the surface if it is still on screen,
  # and otherwise (the organiser left the calendar or switched to the old
  # one) the outcome is flashed here, so it is never lost.
  def handle_info({:calendar_create_result, {draft_id, title}, result}, socket) do
    socket =
      case CalendarRouting.create_settled(socket, draft_id, title, result) do
        :ok ->
          socket

        :off_screen ->
          {kind, message} = Creation.outcome_message(title, result)
          put_flash(socket, kind, message)
      end

    rebuild_agenda({:noreply, socket})
  end

  def handle_info(:calendar_sync_flash, socket),
    do: CalendarEventHandlers.handle_calendar_sync_flash(socket)

  def handle_info(:reset_calendar_sync, socket),
    do: CalendarEventHandlers.handle_reset_calendar_sync(socket)

  def handle_info({:event_update_result, result}, socket),
    do: result |> CalendarEventHandlers.handle_event_update_result(socket) |> rebuild_agenda()

  def handle_info({:event_move_result, result}, socket),
    do: result |> CalendarEventHandlers.handle_event_move_result(socket) |> rebuild_agenda()

  def handle_info({:event_video_result, result}, socket),
    do: CalendarEventHandlers.handle_event_video_result(result, socket)

  def handle_info({:event_writes_released, release}, socket),
    do: CalendarEventHandlers.handle_event_writes_released(release, socket)

  def handle_info({:execute_create_event, payload}, socket),
    do: CalendarEventHandlers.handle_execute_create_event(payload, socket)

  def handle_info({:create_event_result, result}, socket),
    do: result |> CalendarEventHandlers.handle_create_event_result(socket) |> rebuild_agenda()

  def handle_info({:execute_create_ad_hoc_meeting, params}, socket),
    do: CalendarEventHandlers.handle_execute_create_ad_hoc_meeting(params, socket)

  def handle_info({:create_ad_hoc_meeting_result, result}, socket),
    do:
      result
      |> CalendarEventHandlers.handle_create_ad_hoc_meeting_result(socket)
      |> rebuild_agenda()

  def handle_info({:execute_ics_import, payload}, socket),
    do: CalendarEventHandlers.handle_execute_ics_import(payload, socket)

  def handle_info({:ics_import_progress, done}, socket),
    do: CalendarEventHandlers.handle_ics_import_progress(done, socket)

  def handle_info({:ics_import_result, result}, socket),
    do: CalendarEventHandlers.handle_ics_import_result(result, socket)

  def handle_info({:execute_delete_event, payload}, socket),
    do: CalendarEventHandlers.handle_execute_delete_event(payload, socket)

  def handle_info({:delete_event_result, result}, socket),
    do: result |> CalendarEventHandlers.handle_delete_event_result(socket) |> rebuild_agenda()

  def handle_info(_message, _socket), do: :unhandled

  defp rebuild_agenda({:noreply, socket}), do: {:noreply, AgendaRefresh.refresh(socket)}
end
