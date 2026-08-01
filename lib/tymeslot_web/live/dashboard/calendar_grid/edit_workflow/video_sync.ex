defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.VideoSync do
  @moduledoc "Asynchronous video-integration provisioning for inline event edits."

  require Logger

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Rooms, as: VideoRooms

  @doc """
  Asynchronously synchronises the video integration selection for an event.

  Compares the `:video_integration_id` on `updated_event` against
  `original_event`. When unchanged, returns the socket immediately with no
  side effects. When changed, spawns a supervised task that provisions a
  meeting room via `Tymeslot.Integrations.Video.Rooms.create_meeting_room/2`
  (or clears the link when the new ID is `nil`), persists the result to the
  cached event row, then sends `{:video_sync_result, event_id, result}` to
  the LiveView process, where `result` is `{:ok, url_or_nil}` or
  `{:error, reason}`.

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
        result = provision_video_link(updated_event, new_id, user_id)
        send(lv_pid, {:video_sync_result, event_id, result})
      end)

      socket
    end
  end

  defp provision_video_link(event, nil, _user_id) do
    persist_video_link(event, nil)
    {:ok, nil}
  end

  defp provision_video_link(event, integration_id, user_id) do
    opts = [integration_id: integration_id, event_details: EventDetails.from_grid_event(event)]

    case video_rooms_module().create_meeting_room(user_id, opts) do
      {:ok, meeting_context} ->
        persist_meeting_url(event, meeting_context, integration_id, user_id)

      {:error, reason} = error ->
        Logger.warning("Failed to provision video room for event edit",
          user_id: user_id,
          event_id: Map.get(event, :id),
          video_integration_id: integration_id,
          reason: inspect(reason)
        )

        error
    end
  end

  # The provider reported success but the room carries no usable join URL
  # (e.g. a 2xx response whose body is missing the URL field — `RoomData`
  # only enforces key presence, not a non-nil value). Persisting `nil` here
  # would return `{:ok, nil}`, the same shape as an intentional "video
  # removed", so `CalendarEventHandlers.handle_video_sync_result/3` would
  # silently wipe the cached row's link with no flash. Leave the existing
  # `video_link` untouched and surface a distinct error instead so the
  # LiveView can flash it.
  defp persist_meeting_url(event, %{room_data: %{meeting_url: url}}, _integration_id, _user_id)
       when is_binary(url) and url != "" do
    persist_video_link(event, url)
    {:ok, url}
  end

  defp persist_meeting_url(event, _meeting_context, integration_id, user_id) do
    Logger.warning("Video provider returned no meeting URL for event edit",
      user_id: user_id,
      event_id: Map.get(event, :id),
      video_integration_id: integration_id
    )

    {:error, :missing_meeting_url}
  end

  defp persist_video_link(event, url) do
    timing =
      if event.all_day do
        %{start_date: event.start_date, end_date: event.end_date}
      else
        %{start_at: event.start_at, end_at: event.end_at}
      end

    CalendarGrid.update_cached_event(
      Map.merge(timing, %{
        uid: event.uid,
        calendar_integration_id: event.calendar_integration_id,
        provider: event.provider,
        provider_calendar_id: event.provider_calendar_id,
        provider_event_id: event.provider_event_id,
        summary: event.summary,
        all_day: event.all_day,
        location: event.location,
        description: event.description,
        attendees: event.attendees || [],
        status: event.status,
        provider_metadata: event.provider_metadata,
        video_link: url,
        synced_at: DateTime.utc_now(:microsecond)
      })
    )
  end

  defp video_rooms_module do
    Application.get_env(:tymeslot, :video_rooms_module, VideoRooms)
  end
end
