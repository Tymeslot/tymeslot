defmodule Tymeslot.Workers.OrphanedVideoRoomScanChainTest do
  @moduledoc """
  The daily orphaned-room scan end to end: the scan finds a cancelled meeting
  still holding a provider room, enqueues a `VideoSyncWorker` delete, and the
  job deletes the room on the provider and clears it from the meeting, so the
  next scan no longer finds it. The scan's selection alone is covered in
  `OrphanedVideoRoomScanWorkerTest`.
  """

  # Not async: the Zoom video breaker is an application-wide singleton.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :video

  import Mox
  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Repo
  alias Tymeslot.Workers.OrphanedVideoRoomScanWorker
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  test "a cancelled meeting's leftover room is deleted on the provider and cleared" do
    %{user: user} = create_user_with_profile()
    integration = insert(:zoom_video_integration, user: user)
    now = DateTime.utc_now(:second)

    orphan =
      insert_meeting_for_user(user, %{
        start_offset: 2 * 3600,
        duration: 1800,
        status: :cancelled,
        cancelled_at: DateTime.add(now, -7200, :second),
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "86360699337",
        video_room_enabled: true,
        organizer_video_url: "https://zoom.example.com/s/86360699337",
        attendee_video_url: "https://zoom.example.com/j/86360699337"
      })

    assert :ok = perform_job(OrphanedVideoRoomScanWorker, %{})

    assert [job] =
             all_enqueued(
               worker: VideoSyncWorker,
               args: %{"meeting_id" => orphan.id, "action" => "delete"}
             )

    stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert url == "https://api.zoom.us/v2/meetings/86360699337"
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    assert :ok = perform_job(VideoSyncWorker, job.args)

    cleaned = Repo.reload!(orphan)
    assert cleaned.video_room_id == nil
    refute cleaned.video_room_enabled
    assert cleaned.organizer_video_url == nil
    assert cleaned.attendee_video_url == nil

    # Converged: the next scan has nothing left to enqueue for it.
    Repo.delete!(job)
    assert :ok = perform_job(OrphanedVideoRoomScanWorker, %{})
    refute_enqueued(worker: VideoSyncWorker, args: %{"meeting_id" => orphan.id})
  end
end
