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
  for cancelled meetings.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Workers.VideoSyncWorker

  require Logger

  @default_retention_days 7

  # A room nothing could delete within a month of falling due, typically
  # because its integration was disconnected and never replaced, is left to its
  # owner rather than retried every night for ever.
  @lookback_days 30

  @seconds_per_day 86_400

  @impl Oban.Worker
  def perform(_job) do
    # Read at run time: `config/runtime.exs` sets it from the environment.
    retention_days =
      Application.get_env(:tymeslot, :video_room_retention_days, @default_retention_days)

    ended_before = DateTime.add(DateTime.utc_now(), -retention_days * @seconds_per_day, :second)
    ended_after = DateTime.add(ended_before, -@lookback_days * @seconds_per_day, :second)

    meetings =
      MeetingListQueries.list_ended_with_video_room(
        ProviderConfig.rooms_deleted_after_meeting(),
        ended_before,
        ended_after
      )

    enqueued =
      Enum.count(meetings, fn meeting ->
        match?({:ok, _status}, VideoSyncWorker.enqueue(meeting.id, "delete"))
      end)

    Logger.info("Expired video room clean-up completed",
      total_meetings: length(meetings),
      enqueued: enqueued,
      retention_days: retention_days
    )

    :ok
  end
end
