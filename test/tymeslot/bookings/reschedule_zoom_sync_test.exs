defmodule Tymeslot.Bookings.RescheduleZoomSyncTest do
  @moduledoc """
  Zoom video-room sync coverage for `Tymeslot.Bookings.Reschedule.execute/4`,
  split out of `reschedule_test.exs` to keep that module under the line-count
  limit.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :bookings

  import Mox

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.ZoomOAuthHelperMock
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "Zoom video room sync" do
    test "still enqueues the update job after the integration was disconnected" do
      %{user: user, profile: _profile} = create_always_bookable_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "123456789",
          title: "Customer call"
        })

      assert {:ok, :deleted} = Video.delete_integration(user.id, integration.id)

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      assert updated.video_integration_id == nil

      # Otherwise the Zoom meeting keeps advertising the old time on a join URL
      # the attendee still holds.
      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => updated.id, "action" => "update"}
      )
    end

    test "enqueues a video-sync update job that PATCHes the Zoom meeting with new times" do
      %{user: user, profile: _profile} = create_always_bookable_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "123456789",
          title: "Customer call"
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      # The provider PATCH is deferred to a supervised, retrying Oban job — not
      # made inline — so a transient Zoom failure no longer permanently
      # desyncs the meeting's scheduled time.
      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => updated.id, "action" => "update"}
      )

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, url, body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/123456789"
        assert {"Authorization", "Bearer access-token"} in headers

        decoded = Jason.decode!(body)
        assert decoded["topic"] == "Customer call"
        # The job re-reads the meeting, so the PATCH carries the *new* duration.
        assert decoded["duration"] == 60
        assert decoded["start_time"] == DateTime.to_iso8601(updated.start_time)

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => updated.id, "action" => "update"})
    end

    test "still reschedules successfully and the job retries when Zoom update fails" do
      %{user: user, profile: _profile} = create_always_bookable_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "777"
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => updated.id, "action" => "update"}
      )

      # A transient Zoom failure surfaces as {:error, _} from the job so Oban
      # retries it.
      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => updated.id, "action" => "update"})
    end

    test "does not enqueue a video-sync job when meeting has no video_room_id" do
      %{user: user, profile: _profile} = create_always_bookable_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: nil
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, _updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      refute_enqueued(worker: VideoSyncWorker)
    end
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
      oauth_scope: "meeting:write:meeting",
      provider_account_id: nil
    )
  end
end
