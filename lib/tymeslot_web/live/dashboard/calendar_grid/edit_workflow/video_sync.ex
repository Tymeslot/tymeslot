defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.VideoSync do
  @moduledoc "Asynchronous video-integration provisioning for inline event edits."

  alias Tymeslot.CalendarGrid

  @doc """
  Asynchronously synchronises the video integration selection for an event.

  Compares the `:video_integration_id` on `updated_event` against
  `original_event`. When unchanged, returns the socket immediately with no
  side effects. When changed, spawns a supervised task that runs
  `Tymeslot.CalendarGrid.change_event_video/3`, then sends
  `{:video_sync_result, event_id, result}` to the LiveView process.

  Returns the (unchanged) socket immediately so callers are never blocked by
  the network round-trip to the video provider.
  """
  @spec sync_video_integration_async(
          Phoenix.LiveView.Socket.t(),
          map(),
          map()
        ) :: Phoenix.LiveView.Socket.t()
  def sync_video_integration_async(socket, original_event, updated_event) do
    old_id = Map.get(original_event, :video_integration_id)
    new_id = Map.get(updated_event, :video_integration_id)

    if old_id == new_id do
      socket
    else
      user_id = socket.assigns.current_user.id
      event_id = Map.get(updated_event, :id)
      lv_pid = self()

      Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
        result = CalendarGrid.change_event_video(user_id, original_event, new_id)
        send(lv_pid, {:video_sync_result, event_id, result})
      end)

      socket
    end
  end
end
