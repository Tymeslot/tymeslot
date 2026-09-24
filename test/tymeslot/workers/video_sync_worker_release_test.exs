defmodule Tymeslot.Workers.VideoSyncWorkerReleaseTest do
  @moduledoc """
  Drives the video-room sync worker's `"release"` action: deleting a provider
  room that a rescheduled meeting let go of when it moved to another video
  integration. The job carries the room's identity in its own args, because
  the meeting no longer points at the room by the time it runs.
  """

  # Not async, like `Tymeslot.Workers.VideoSyncWorkerTest`: these tests call
  # the Zoom provider through the application-wide video circuit breaker.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :workers

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  describe "release/1" do
    test "copies the room's identity into the job, keyed by room" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{video_provider: "zoom", video_room_id: "first-room"})

      assert {:ok, :scheduled} = VideoSyncWorker.release(meeting)
      assert {:ok, :already_scheduled} = VideoSyncWorker.release(meeting)

      # A second room released from the same meeting is its own job.
      assert {:ok, :scheduled} =
               VideoSyncWorker.release(%{meeting | video_room_id: "second-room"})

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{
          "action" => "release",
          "meeting_id" => meeting.id,
          "room_id" => "first-room",
          "video_provider" => "zoom",
          "organizer_user_id" => user.id
        }
      )
    end
  end

  describe "release/1 for a Teams meeting on the booking's own calendar event" do
    test "enqueues nothing, since deleting the room would delete the booking's event" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          video_provider: "teams",
          video_room_id: "AAMk-booking-event",
          provider_event_id: "AAMk-booking-event"
        })

      assert VideoSyncWorker.release(meeting) == {:ok, :calendar_event}
      refute_enqueued(worker: VideoSyncWorker)
    end

    test "still releases a Teams room that is an event of its own" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          video_provider: "teams",
          video_room_id: "AAMk-own-event",
          provider_event_id: "AAMk-booking-event"
        })

      assert {:ok, :scheduled} = VideoSyncWorker.release(meeting)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"action" => "release", "room_id" => "AAMk-own-event"}
      )
    end
  end

  describe "perform/1 — release" do
    test "DELETEs the room from the args and leaves the meeting alone" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      # The meeting has since moved on to a room of its own; the release must
      # not touch it.
      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "new-room"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/old-room"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = perform_job(VideoSyncWorker, release_args(meeting, integration.id, "old-room"))
      assert Repo.reload!(meeting).video_room_id == "new-room"
    end

    test "falls back to the user's current integration when the recorded one is gone" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)
      insert_zoom_integration(user)

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/old-room"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      # An id no integration row carries any more, as after a disconnect.
      assert :ok = perform_job(VideoSyncWorker, release_args(meeting, 987_654_321, "old-room"))
    end

    test "waits for a reconnect instead of discarding an unreachable room" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      assert {:snooze, 86_400} =
               perform_job(VideoSyncWorker, release_args(meeting, nil, "old-room"))
    end

    test "gives up loudly once the wait is spent" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      events =
        LogCapture.with_capture(fn ->
          assert {:discard, _reason} =
                   perform_job(VideoSyncWorker, release_args(meeting, nil, "old-room"),
                     meta: %{"snoozed" => 13}
                   )

          LogCapture.drain()
        end)

      logged = Enum.map_join(events, "\n", &LogCapture.dump/1)

      assert logged =~ "no video integration can reach it"
      assert logged =~ "action: \"release\""
      assert logged =~ "meeting_id: \"#{meeting.id}\""
      refute logged =~ "old-room"
    end
  end

  defp release_args(meeting, integration_id, room_id) do
    %{
      "action" => "release",
      "meeting_id" => meeting.id,
      "room_id" => room_id,
      "video_provider" => "zoom",
      "video_integration_id" => integration_id,
      "organizer_user_id" => meeting.organizer_user_id
    }
  end

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:update:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
  end
end
