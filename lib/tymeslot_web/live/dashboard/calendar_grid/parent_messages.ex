defmodule TymeslotWeb.Dashboard.CalendarGrid.ParentMessages do
  @moduledoc """
  The old calendar grid's share of `DashboardLive`'s mailbox: its clock
  tick, its create and delete round trips, and its sync flash and fallback
  refresh.
  `TymeslotWeb.Dashboard.CalendarMessages` hands it every message it does
  not act on itself; `handle_info/2` answers `:unhandled` for any other.

  It sits beside the grid so that it goes with it: the new surface neither
  sends nor needs any of these.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.Dashboard.AgendaRefresh
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCrud
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Dashboard.CalendarRouting

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Acts on one of the old grid's messages, or answers `:unhandled` for any other."
  @spec handle_info(term(), socket()) :: {:noreply, socket()} | :unhandled
  def handle_info(:tick, socket) do
    if CalendarRouting.grid_on_screen?(socket) do
      Process.send_after(self(), :tick, 60_000)
      send_update(CalendarGridComponent, id: "calendar", current_time: Clock.utc_now())
    end

    {:noreply, socket}
  end

  def handle_info(:calendar_sync_flash, socket) do
    {:noreply,
     put_flash(socket, :info, dgettext("dashboard_calendar_events", "Calendars refreshed"))}
  end

  def handle_info(:reset_calendar_sync, socket) do
    CalendarRouting.refresh(socket, :refresh_events)
    {:noreply, socket}
  end

  def handle_info({:execute_create_event, payload}, socket) do
    lv_pid = self()

    Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:create_event_result, Changes.create_event(payload.user_id, payload)})
    end)

    {:noreply, socket}
  end

  def handle_info({:create_event_result, result}, socket),
    do: result |> EventCrud.handle_create_result(socket) |> rebuild_agenda()

  # Every way the grid confirms a delete ends here, so the seat lock is
  # checked once more, against the database: an event a group meeting with
  # live seats sits on is never deleted from the grid.
  def handle_info({:execute_delete_event, payload}, socket) do
    case Shared.check_seat_lock(socket, payload) do
      :ok ->
        start_delete(payload, socket)

      {:error, :group_booking} ->
        send_update(CalendarGridComponent, id: "calendar", action: :event_delete_failed)
        {:noreply, put_flash(socket, :warning, Shared.seat_lock_message())}
    end
  end

  def handle_info({:delete_event_result, result}, socket),
    do: result |> EventCrud.handle_delete_result(socket) |> rebuild_agenda()

  def handle_info(_message, _socket), do: :unhandled

  defp start_delete(payload, socket) do
    socket
    |> EditWorkflow.run_async(
      :delete_event_result,
      fn ->
        Changes.delete_event(payload.user_id, payload, payload.scope,
          notify_attendees: payload.notify_on_delete
        )
      end,
      {:error, %{reason: :crashed, retry: :not_queued}}
    )
    |> assign(:pending_delete, Map.take(payload, [:notify_on_delete, :scope]))
    |> then(&{:noreply, &1})
  end

  defp rebuild_agenda({:noreply, socket}), do: {:noreply, AgendaRefresh.refresh(socket)}
end
