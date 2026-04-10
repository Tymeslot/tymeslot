defmodule TymeslotWeb.Dashboard.CalendarEventHandlers do
  @moduledoc """
  Handles calendar-related `handle_info/2` messages for `DashboardLive`.

  Each public function accepts the message payload and the socket, returning
  `{:noreply, socket}` so the caller can delegate directly.
  """

  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCrud
  alias TymeslotWeb.Dashboard.CalendarGridComponent

  @doc "Advances the clock-tick timer and pushes the current time to the calendar grid."
  @spec handle_tick(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_tick(socket) do
    if socket.assigns.live_action == :calendar do
      Process.send_after(self(), :tick, 60_000)

      send_update(CalendarGridComponent,
        id: "calendar",
        current_time: DateTime.utc_now()
      )
    end

    {:noreply, socket}
  end

  @doc "Notifies the calendar grid that upstream events have changed."
  @spec handle_calendar_events_updated(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_events_updated(socket) do
    if socket.assigns.live_action == :calendar do
      send_update(CalendarGridComponent,
        id: "calendar",
        action: :events_updated
      )
    end

    {:noreply, socket}
  end

  @doc "Notifies the calendar grid that an integration sync completed."
  @spec handle_calendar_sync_complete(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_sync_complete(socket) do
    if socket.assigns.live_action == :calendar do
      send_update(CalendarGridComponent,
        id: "calendar",
        action: :integration_synced
      )
    end

    {:noreply, socket}
  end

  @doc "Flashes a confirmation after calendar sync."
  @spec handle_calendar_sync_flash(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_sync_flash(socket) do
    {:noreply, put_flash(socket, :info, "Calendars refreshed")}
  end

  @doc "Tells the calendar grid to refresh its event data."
  @spec handle_reset_calendar_sync(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reset_calendar_sync(socket) do
    if socket.assigns.live_action == :calendar do
      send_update(CalendarGridComponent,
        id: "calendar",
        action: :refresh_events
      )
    end

    {:noreply, socket}
  end

  @doc "Handles the result of an event update — no-op on success, reverts on failure."
  @spec handle_event_update_result(:ok | {:error, keyword()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_update_result(:ok, socket), do: {:noreply, socket}

  def handle_event_update_result({:error, payload}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :revert_event,
      original_event: payload[:original_event]
    )

    {:noreply, put_flash(socket, :error, "Failed to update event — changes reverted")}
  end

  @doc "Handles the result of an event move — updates the grid or reverts on failure."
  @spec handle_event_move_result(
          {:ok, keyword()} | {:error, keyword()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_move_result({:ok, new_event_info}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_moved,
      new_event_uid: new_event_info[:uid],
      new_event_integration_id: new_event_info[:integration_id]
    )

    {:noreply, socket}
  end

  def handle_event_move_result({:error, payload}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :revert_event,
      original_event: payload[:original_event]
    )

    {:noreply, put_flash(socket, :error, "Failed to move event")}
  end

  @doc "Spawns a supervised task to create a calendar event."
  @spec handle_execute_create_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_create_event(payload, socket) do
    lv_pid = self()

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:create_event_result, EventCrud.run_create_event(payload)})
    end)

    {:noreply, socket}
  end

  @doc "Delegates the create-event result to `EventCrud`."
  @spec handle_create_event_result(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_event_result(result, socket) do
    EventCrud.handle_create_result(result, socket)
  end

  @doc "Spawns a supervised task to create an ad-hoc meeting."
  @spec handle_execute_create_ad_hoc_meeting(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_create_ad_hoc_meeting(params, socket) do
    lv_pid = self()

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:create_ad_hoc_meeting_result, EventCrud.run_create_ad_hoc_meeting(params)})
    end)

    {:noreply, socket}
  end

  @doc "Handles the result of an ad-hoc meeting creation."
  @spec handle_create_ad_hoc_meeting_result(
          {:ok, any()} | {:error, String.t()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_ad_hoc_meeting_result({:ok, _result}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :ad_hoc_meeting_created
    )

    {:noreply, put_flash(socket, :info, "Meeting created and invitation sent")}
  end

  def handle_create_ad_hoc_meeting_result({:error, reason}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :ad_hoc_meeting_failed
    )

    {:noreply, put_flash(socket, :error, reason)}
  end

  @doc "Spawns a supervised task to delete a calendar event."
  @spec handle_execute_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_delete_event(payload, socket) do
    lv_pid = self()

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:delete_event_result, EventCrud.run_delete_event(payload)})
    end)

    {:noreply, socket}
  end

  @doc "Delegates the delete-event result to `EventCrud`."
  @spec handle_delete_event_result(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete_event_result(result, socket) do
    EventCrud.handle_delete_result(result, socket)
  end
end
