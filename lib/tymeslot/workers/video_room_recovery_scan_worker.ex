defmodule Tymeslot.Workers.VideoRoomRecoveryScanWorker do
  @moduledoc """
  Daily scan to recover meetings missing video room links.

  Ensures confirmed upcoming meetings with video integrations are queued
  for video room creation if the link was missed earlier.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]
  require Logger

  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Workers.VideoRoomWorker

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    meetings = MeetingListQueries.list_meetings_missing_video_rooms(now)

    scheduled_count =
      Enum.reduce(meetings, 0, fn meeting, acc ->
        case VideoRoomWorker.schedule_video_room_creation(meeting.id) do
          :ok -> acc + 1
          {:error, _reason} -> acc
        end
      end)

    Logger.info("Video room recovery scan completed",
      total_meetings: length(meetings),
      scheduled_count: scheduled_count
    )

    :ok
  rescue
    error ->
      Logger.error("Video room recovery scan failed", error: error)
      {:error, Exception.message(error)}
  end
end
