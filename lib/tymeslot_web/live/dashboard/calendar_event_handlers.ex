defmodule TymeslotWeb.Dashboard.CalendarEventHandlers do
  @moduledoc """
  Handles calendar-related `handle_info/2` messages for `DashboardLive`.

  Each public function accepts the message payload and the socket, returning
  `{:noreply, socket}` so the caller can delegate directly.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
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
    {:noreply,
     put_flash(socket, :info, dgettext("dashboard_calendar_events", "Calendars refreshed"))}
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

  @doc """
  Handles the result of an event update: nothing to do on success; on
  failure, keeps the edit when it was queued to sync later and reverts it
  otherwise.
  """
  @spec handle_event_update_result(:ok | {:error, keyword()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_update_result(:ok, socket), do: {:noreply, socket}

  def handle_event_update_result({:error, payload}, socket) do
    if payload[:retry] == :queued do
      {:noreply,
       put_flash(
         socket,
         :warning,
         dgettext(
           "dashboard_calendar_events",
           "Your calendar could not be reached. The change is saved and will sync on the next attempt."
         )
       )}
    else
      revert_failed_update(payload, socket)
    end
  end

  defp revert_failed_update(payload, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :revert_event,
      original_event: payload[:original_event]
    )

    {:noreply,
     put_flash(
       socket,
       :error,
       dgettext("dashboard_calendar_events", "Failed to update event - changes reverted")
     )}
  end

  @doc """
  Handles the result of an event move: shows the moved event and says where
  the original ended up, or reverts the grid when nothing was moved.
  """
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

    {level, message} = moved_flash(new_event_info[:source])
    {:noreply, put_flash(socket, level, message)}
  end

  def handle_event_move_result({:error, payload}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :revert_event,
      original_event: payload[:original_event]
    )

    {:noreply, put_flash(socket, :error, move_failed_message(payload[:reason]))}
  end

  defp moved_flash(nil),
    do: {:info, dgettext("dashboard_calendar_events", "Event moved to the new calendar.")}

  defp moved_flash(:queued_delete) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar. The original will be removed on the next sync."
     )}
  end

  defp moved_flash(:left_behind) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar, but the original could not be removed. Please delete it from its original calendar."
     )}
  end

  defp move_failed_message(:recurring_event), do: EditWorkflow.recurring_move_refused_message()

  defp move_failed_message(_reason) do
    dgettext(
      "dashboard_calendar_events",
      "Could not move the event. It is still on its original calendar."
    )
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

    {:noreply,
     put_flash(
       socket,
       :info,
       dgettext("dashboard_calendar_events", "Meeting created and invitation sent")
     )}
  end

  def handle_create_ad_hoc_meeting_result({:error, reason}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :ad_hoc_meeting_failed
    )

    {:noreply, put_flash(socket, :error, reason)}
  end

  @doc "Applies the result of an async video room provisioning to the calendar grid."
  @spec handle_video_sync_result(
          integer() | nil,
          {:ok, String.t() | nil} | {:error, term()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_video_sync_result(_event_id, {:error, _reason}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       dgettext("dashboard_calendar_events", "Failed to provision video room - link not updated")
     )}
  end

  def handle_video_sync_result(event_id, {:ok, video_link}, socket) do
    if socket.assigns.live_action == :calendar do
      send_update(CalendarGridComponent,
        id: "calendar",
        action: :video_link_updated,
        event_id: event_id,
        video_link: video_link
      )
    end

    {:noreply, socket}
  end

  @doc "Spawns a supervised task to delete a calendar event."
  @spec handle_execute_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_delete_event(payload, socket) do
    lv_pid = self()
    notify_on_delete = Map.get(payload, :notify_on_delete, false)

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:delete_event_result, EventCrud.run_delete_event(payload)})
    end)

    {:noreply, assign(socket, :pending_delete_notify, notify_on_delete)}
  end

  @doc "Delegates the delete-event result to `EventCrud`."
  @spec handle_delete_event_result(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete_event_result(result, socket) do
    EventCrud.handle_delete_result(result, socket)
  end
end
