defmodule Tymeslot.Bookings.BookingZoomIntegrationTest do
  @moduledoc """
  End-to-end integration test for the public booking → Zoom meeting journey.

  Covers the full chain a Zoom App Marketplace reviewer exercises:

  1. A booking is submitted through `Orchestrator.submit_booking/2` against a
     meeting type whose video provider is Zoom (the integration is resolved
     from the meeting type, not passed in the form params).
  2. The booking enqueues `VideoRoomWorker`.
  3. The worker creates the Zoom meeting, firing both Zoom API calls the app's
     scopes are granted for: `POST /users/me/meetings` (meeting:write:meeting)
     and the read-back `GET /meetings/{id}` (meeting:read:meeting).
  4. The Zoom join link is attached to the meeting.

  The provider/worker layers are unit-tested separately; this test guards the
  seam between them so a booking can never silently skip the Zoom API calls.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  setup do
    # The booking flow checks the organizer's calendar for conflicts.
    TestMocks.setup_calendar_mocks()

    user = insert(:user, email: "host@example.com", name: "Zoom Host")
    _profile = insert(:profile, user: user, timezone: "America/New_York")

    zoom_integration =
      insert(:video_integration,
        user: user,
        provider: "zoom",
        is_active: true,
        oauth_scope: "meeting:write:meeting"
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Zoom Consultation",
        duration_minutes: 30,
        is_active: true,
        allow_video: true,
        video_integration_id: zoom_integration.id
      )

    %{user: user, zoom_integration: zoom_integration, meeting_type: meeting_type}
  end

  describe "booking a Zoom-enabled meeting type" do
    test "fires the Zoom create and read API calls and attaches the join link", %{
      user: user,
      zoom_integration: zoom_integration,
      meeting_type: meeting_type
    } do
      # Build the submission exactly as the public booking form does — note the
      # form never sends a video_integration_id; it must resolve from the
      # meeting type. `with_video_room: true` is always set by the form.
      params = %{
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => "Looking forward to it"
        },
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "14:00",
          duration: "30min",
          user_timezone: "America/New_York",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id,
          with_video_room: true
        }
      }

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      # Zoom room creation makes exactly two HTTP calls: the create POST and the
      # best-effort read-back GET. verify_on_exit! enforces that both fire.
      expect_zoom_success()

      # Step 1: submit the booking — resolves Zoom from the meeting type and
      # enqueues the video room worker.
      assert {:ok, meeting} =
               Orchestrator.submit_booking(params, organizer_user_id: user.id)

      assert meeting.status == "confirmed"
      assert meeting.video_integration_id == zoom_integration.id

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "send_emails" => true}
      )

      # Step 2: run the worker — this is where the Zoom API calls fire.
      assert :ok =
               perform_job(VideoRoomWorker, %{
                 "meeting_id" => meeting.id,
                 "send_emails" => true
               })

      # The Zoom meeting is now attached to the booking.
      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_enabled
      assert updated.video_room_id =~ "12345678901"
      assert updated.meeting_url =~ "zoom.us"
    end

    test "the Zoom create POST carries the booking's real start time, duration and topic", %{
      user: user,
      meeting_type: meeting_type
    } do
      params = %{
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => "Looking forward to it"
        },
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "14:00",
          duration: "30min",
          user_timezone: "America/New_York",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id,
          with_video_room: true
        }
      }

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      assert {:ok, meeting} = Orchestrator.submit_booking(params, organizer_user_id: user.id)

      # Capture the create POST body and assert it reflects the *booking*, not
      # the old utc_now()+1h / 30min / "Scheduled Meeting" defaults.
      expect(Tymeslot.HTTPClientMock, :request, 2, fn
        :post, _url, body, _headers, _opts ->
          decoded = Jason.decode!(body)

          # Duration comes from the booking (30 min), not the hardcoded default.
          assert decoded["duration"] == 30

          # Topic comes from the meeting's summary/title, never "Scheduled Meeting".
          refute decoded["topic"] == "Scheduled Meeting"
          assert is_binary(decoded["topic"]) and decoded["topic"] != ""

          # Start time matches the persisted booking start, not utc_now()+1h.
          {:ok, sent_start, _offset} = DateTime.from_iso8601(decoded["start_time"])
          assert DateTime.compare(sent_start, meeting.start_time) == :eq

          {:ok,
           %Req.Response{
             status: 201,
             body: Jason.encode!(%{"id" => 12_345_678_901, "join_url" => "https://zoom.us/j/123"})
           }}

        :get, _url, _body, _headers, _opts ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(%{"id" => 12_345_678_901, "status" => "waiting"})
           }}
      end)

      assert :ok =
               perform_job(VideoRoomWorker, %{
                 "meeting_id" => meeting.id,
                 "send_emails" => true
               })
    end
  end
end
