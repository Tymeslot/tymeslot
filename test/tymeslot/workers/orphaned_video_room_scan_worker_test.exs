defmodule Tymeslot.Workers.OrphanedVideoRoomScanWorkerTest do
  @moduledoc """
  Drives the daily scan that re-enqueues provider deletion for cancelled
  meetings still holding a video room, including the rooms orphaned by releases
  that predate the fallback resolution.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers

  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Workers.OrphanedVideoRoomScanWorker
  alias Tymeslot.Workers.VideoSyncWorker

  test "enqueues a delete for a cancelled meeting that still holds a room" do
    %{user: user} = create_user_with_profile()

    orphan =
      insert_cancelled(user, -2,
        cancelled_ago: 7200,
        video_provider: "zoom",
        video_room_id: "86360699337"
      )

    assert :ok = perform_job(OrphanedVideoRoomScanWorker, %{})

    assert_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => orphan.id, "action" => "delete"}
    )
  end

  test "skips a meeting cancelled moments ago so it cannot race the cancellation job" do
    %{user: user} = create_user_with_profile()

    fresh =
      insert_cancelled(user, -3,
        cancelled_ago: 0,
        video_provider: "zoom",
        video_room_id: "111"
      )

    assert :ok = perform_job(OrphanedVideoRoomScanWorker, %{})

    refute_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => fresh.id, "action" => "delete"}
    )
  end

  test "ignores cancelled meetings whose room was already cleaned" do
    %{user: user} = create_user_with_profile()

    cleaned =
      insert_cancelled(user, -4,
        cancelled_ago: 7200,
        video_provider: "zoom",
        video_room_id: nil
      )

    assert :ok = perform_job(OrphanedVideoRoomScanWorker, %{})

    refute_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => cleaned.id, "action" => "delete"}
    )
  end

  test "ignores confirmed meetings, whose rooms are still in use" do
    %{user: user} = create_user_with_profile()

    live_booking =
      insert_meeting_for_user(user, %{
        video_provider: "zoom",
        video_room_id: "still-needed"
      })

    assert :ok = perform_job(OrphanedVideoRoomScanWorker, %{})

    refute_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => live_booking.id, "action" => "delete"}
    )
  end

  # `hours_out` keeps each meeting in its own slot: a unique index forbids two
  # meetings for the same organiser at the same time.
  defp insert_cancelled(user, hours_out, opts) do
    cancelled_ago = Keyword.fetch!(opts, :cancelled_ago)
    now = DateTime.utc_now(:second)

    insert_meeting_for_user(user, %{
      start_offset: hours_out * 3600,
      duration: 1800,
      status: "cancelled",
      cancelled_at: DateTime.add(now, -cancelled_ago, :second),
      video_integration_id: nil,
      video_provider: Keyword.get(opts, :video_provider),
      video_room_id: Keyword.get(opts, :video_room_id)
    })
  end
end
