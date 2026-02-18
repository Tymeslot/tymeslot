defmodule Tymeslot.Workers.VideoRoomRecoveryScanWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory

  alias Tymeslot.Workers.VideoRoomRecoveryScanWorker
  alias Tymeslot.Workers.VideoRoomWorker

  describe "perform/1" do
    test "enqueues video room creation for meetings missing links" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      future_start = DateTime.add(DateTime.utc_now(), 2, :day)
      future_end = DateTime.add(future_start, 3600, :second)

      meeting_missing =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: integration.id,
          video_room_id: nil,
          start_time: future_start,
          end_time: future_end
        )

      _meeting_with_video =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: integration.id,
          video_room_id: "existing-room",
          start_time: DateTime.add(future_start, 1, :hour),
          end_time: DateTime.add(future_end, 1, :hour)
        )

      _meeting_without_integration =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: nil,
          start_time: DateTime.add(future_start, 2, :hour),
          end_time: DateTime.add(future_end, 2, :hour)
        )

      past_start = DateTime.add(DateTime.utc_now(), -2, :day)
      past_end = DateTime.add(past_start, 3600, :second)

      _past_meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: integration.id,
          start_time: past_start,
          end_time: past_end
        )

      assert :ok = perform_job(VideoRoomRecoveryScanWorker, %{})

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting_missing.id, "send_emails" => false}
      )

      enqueued = all_enqueued(worker: VideoRoomWorker)
      assert length(enqueued) == 1
    end
  end
end
