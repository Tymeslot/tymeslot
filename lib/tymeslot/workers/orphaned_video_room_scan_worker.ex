defmodule Tymeslot.Workers.OrphanedVideoRoomScanWorker do
  @moduledoc """
  Daily scan for cancelled meetings whose provider-side video room was never
  deleted.

  These accumulated while a disconnected integration made cancellation skip the
  provider call silently. Re-enqueuing `Tymeslot.Workers.VideoSyncWorker` is
  enough: it resolves the integration through
  `Tymeslot.Integrations.Video.IntegrationResolver`, so a room becomes reachable
  again the moment the user reconnects that provider, and a room that stays
  unreachable is logged rather than retried for ever.

  The scan converges because a successful provider delete clears
  `video_room_id`: a cancelled meeting still carrying one is genuinely
  outstanding work, not simply a meeting that once had a room.

  Mirrors `Tymeslot.Workers.VideoRoomRecoveryScanWorker`, which handles the
  opposite failure — meetings missing a room they should have.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Workers.VideoSyncWorker

  require Logger

  # Cancellation enqueues its own delete job with five attempts and a backoff
  # chain of roughly ten minutes. Waiting an hour keeps the scan from racing a
  # job that is still retrying.
  @settle_seconds 3600

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@settle_seconds, :second)
    meetings = MeetingListQueries.list_cancelled_with_video_room(cutoff)

    enqueued =
      Enum.count(meetings, fn meeting ->
        match?({:ok, _status}, VideoSyncWorker.enqueue(meeting.id, "delete"))
      end)

    Logger.info("Orphaned video room scan completed",
      total_meetings: length(meetings),
      enqueued: enqueued
    )

    :ok
  end
end
