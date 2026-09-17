defmodule Tymeslot.Workers.ExpiredVideoRoomCleanupWorker do
  @moduledoc """
  Daily clean-up of video rooms that outlive their meeting.

  Some providers keep a booking's room on the organiser's own server until
  something deletes it: a Nextcloud Talk conversation otherwise stays in the
  organiser's Talk list for ever. `ProviderConfig.rooms_deleted_after_meeting/0`
  names those providers. This scan deletes each such room once its meeting
  ended more than the retention period ago (`VIDEO_ROOM_RETENTION_DAYS`,
  7 by default), which leaves time for a follow-up in the same conversation.

  Deleting is handed to `Tymeslot.Workers.VideoSyncWorker`, which resolves the
  integration, retries a transient failure, treats a room already gone as done
  and clears `video_room_id` on success. That last step is what makes the scan
  converge: a meeting still carrying a room id is still outstanding.

  Mirrors `Tymeslot.Workers.OrphanedVideoRoomScanWorker`, which does the same
  for cancelled meetings, so this scan leaves those to it. Rooms whose
  integration is waiting to be reconnected are skipped until it is.

  Rooms made for events on the dashboard calendar grid have no meeting, so
  they are read from their own records (`Tymeslot.CalendarGrid.EventVideoRooms`)
  and deleted through the same job, which removes each record once its room is
  gone. The same retention, look-back window and skips apply.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Workers.VideoSyncWorker

  require Logger

  # A room nothing could delete within a month of falling due, typically
  # because its integration was disconnected and never replaced, is left to its
  # owner rather than retried every night for ever.
  @lookback_days 30

  @seconds_per_day 86_400

  @impl Oban.Worker
  def perform(_job) do
    # Read at run time: `config/runtime.exs` sets it from the environment, over
    # the default in `config/config.exs`.
    retention_days = Application.fetch_env!(:tymeslot, :video_room_retention_days)

    ended_before = DateTime.add(DateTime.utc_now(), -retention_days * @seconds_per_day, :second)
    ended_after = DateTime.add(ended_before, -@lookback_days * @seconds_per_day, :second)

    providers = ProviderConfig.rooms_deleted_after_meeting()

    meetings = MeetingListQueries.list_ended_with_video_room(providers, ended_before, ended_after)
    event_rooms = EventVideoRoomQueries.list_ended(providers, ended_before, ended_after)

    enqueued =
      Enum.count(meetings, &enqueued?(VideoSyncWorker.enqueue(&1.id, "delete"))) +
        Enum.count(event_rooms, &enqueued?(VideoSyncWorker.enqueue_event_room(&1.id, "delete")))

    Logger.info("Expired video room clean-up completed",
      total_meetings: length(meetings),
      total_calendar_event_rooms: length(event_rooms),
      enqueued: enqueued,
      retention_days: retention_days
    )

    :ok
  end

  defp enqueued?(result), do: match?({:ok, _status}, result)
end
