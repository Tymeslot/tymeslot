defmodule Tymeslot.Bookings.CancelTest do
  @moduledoc """
  Tests for the booking cancellation module.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :bookings

  import Mox

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.ZoomOAuthHelperMock
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup do
    # Setup email mocks for cancellation notifications
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "execute/1 with meeting UID" do
    test "successfully cancels a future meeting" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      assert {:ok, cancelled_meeting} = Cancel.execute(meeting.uid)
      assert cancelled_meeting.status == "cancelled"
      assert cancelled_meeting.cancelled_at != nil
    end

    test "returns error when meeting is not found" do
      assert {:error, :meeting_not_found} = Cancel.execute("non-existent-uid")
    end

    test "returns error when meeting is already cancelled" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{status: "cancelled", start_offset: 3600, duration: 3600})

      assert {:error, "Meeting is already cancelled"} = Cancel.execute(meeting.uid)
    end

    test "returns error when meeting is completed" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -7_200,
          duration: 3_600
        })

      assert {:error, "Cannot cancel a completed meeting"} = Cancel.execute(meeting.uid)
    end

    test "returns error when meeting has already started" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -3_600,
          duration: 7_200
        })

      assert {:error, "Cannot cancel a meeting that has already started"} =
               Cancel.execute(meeting.uid)
    end

    test "returns error when meeting has already occurred" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -7_200,
          duration: 3_600
        })

      assert {:error, "Cannot cancel a meeting that has already occurred"} =
               Cancel.execute(meeting.uid)
    end
  end

  describe "execute/1 with meeting struct" do
    test "successfully cancels a future meeting struct" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      # Reload to ensure we have the full struct
      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:ok, cancelled_meeting} = Cancel.execute(loaded_meeting)
      assert cancelled_meeting.status == "cancelled"
      assert cancelled_meeting.cancelled_at != nil
    end

    test "returns error when meeting is already cancelled" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "cancelled",
          start_offset: 3600,
          duration: 3600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Meeting is already cancelled"} = Cancel.execute(loaded_meeting)
    end

    test "allows cancellation of meeting starting soon" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 600,
          duration: 3_600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:ok, cancelled_meeting} = Cancel.execute(loaded_meeting)
      assert cancelled_meeting.status == "cancelled"
    end
  end

  describe "validate_cancellation/1" do
    test "returns :ok for future meetings" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert :ok = Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for already cancelled meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "cancelled",
          start_offset: 3600,
          duration: 3600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Meeting is already cancelled"} =
               Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for completed meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -7_200,
          duration: 3_600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Cannot cancel a completed meeting"} =
               Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for ongoing meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -3_600,
          duration: 7_200
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Cannot cancel a meeting that has already started"} =
               Cancel.validate_cancellation(loaded_meeting)
    end

    test "returns error for past meetings" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -7_200,
          duration: 3_600
        })

      {:ok, loaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert {:error, "Cannot cancel a meeting that has already occurred"} =
               Cancel.validate_cancellation(loaded_meeting)
    end
  end

  describe "status update side effects" do
    test "persists cancellation status in database" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      assert {:ok, _cancelled_meeting} = Cancel.execute(meeting.uid)

      # Reload from database to verify persistence
      {:ok, reloaded_meeting} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      assert reloaded_meeting.status == "cancelled"
      assert reloaded_meeting.cancelled_at != nil
    end

    test "deletes pending reminder email jobs" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )

      assert {:ok, _cancelled_meeting} = Cancel.execute(meeting.uid)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )
    end
  end

  describe "Zoom video room cleanup" do
    test "enqueues a video-sync delete job that calls the Zoom REST API" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: "987654321"
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      # The provider call is deferred to a supervised, retrying Oban job rather
      # than made inline — so a transient Zoom failure no longer orphans the
      # meeting. The cancellation itself does not touch the Zoom API.
      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => cancelled.id, "action" => "delete"}
      )

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/987654321"
        assert {"Authorization", "Bearer access-token"} in headers

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => cancelled.id, "action" => "delete"})
    end

    test "still cancels successfully and the job retries when Zoom delete fails" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: "555"
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_cancellation_emails", "meeting_id" => cancelled.id}
      )

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => cancelled.id, "action" => "delete"}
      )

      # A transient Zoom failure returns {:error, _} from the job so Oban retries
      # it — the meeting is not permanently desynced.
      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => cancelled.id, "action" => "delete"})
    end

    test "the delete job treats Zoom 404 as success so cancellation is idempotent" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: "gone"
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => cancelled.id, "action" => "delete"})
    end

    test "does not enqueue a video-sync job when meeting has no video_room_id" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          video_integration_id: integration.id,
          video_room_id: nil
        })

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)
      assert cancelled.status == "cancelled"

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
      oauth_scope: "meeting:write:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
  end
end
