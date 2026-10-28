defmodule Tymeslot.Workers.VideoRoomRecoveryScanChainTest do
  @moduledoc """
  The daily recovery scan end to end: the scan finds an upcoming meeting that
  should have a video room and has none, enqueues `VideoRoomWorker`, and the
  job creates the room on the provider and records it on the meeting. The
  scan's selection alone is covered in `VideoRoomRecoveryScanWorkerTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :video

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.VideoRoomRecoveryScanWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  @room_url "https://test.mirotalk.com/join/recovered-room"

  test "a meeting the scan finds without a room ends up with one" do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    integration = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

    start_time = DateTime.add(DateTime.utc_now(:second), 2, :day)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        video_integration_id: integration.id,
        video_room_id: nil,
        start_time: start_time,
        end_time: DateTime.add(start_time, 3600, :second)
      )

    assert :ok = perform_job(VideoRoomRecoveryScanWorker, %{})

    assert [job] = all_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})

    expect_mirotalk_success(@room_url)

    assert :ok = perform_job(VideoRoomWorker, job.args)

    recovered = Repo.get!(MeetingSchema, meeting.id)
    assert recovered.video_room_id == @room_url
    assert recovered.video_room_enabled
    assert recovered.organizer_video_url == "#{@room_url}?token=abc"
    assert recovered.attendee_video_url == "#{@room_url}?token=abc"
  end
end
