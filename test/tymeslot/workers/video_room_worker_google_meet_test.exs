defmodule Tymeslot.Workers.VideoRoomWorkerGoogleMeetTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo
  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  @meeting_url "https://meet.google.com/abc-defg-hij"

  # Emails hand each person their role's URL while the dashboard and the ICS
  # file show `meeting_url`. For Meet all three must be the same link, or an
  # attendee not signed in to Google under their booking address is sent to a
  # sign-in page instead of the room.
  test "gives every Google Meet participant the same plain meeting link" do
    user = insert(:user)
    _profile = insert(:profile, user: user)

    integration =
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        oauth_scope: "https://www.googleapis.com/auth/meetings.space.created",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      )

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_email: "guest@example.com",
        video_integration_id: integration.id
      )

    # Booked to no calendar, so the Meet is a space of its own rather than
    # the conference Google makes on a booking's Google event.
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _meeting ->
      {:error, :no_integration}
    end)

    expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      space = %{"name" => "spaces/NgPxrxVDQF8B", "meetingUri" => @meeting_url}
      {:ok, %Req.Response{status: 200, body: Jason.encode!(space)}}
    end)

    assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

    updated_meeting = Repo.get(MeetingSchema, meeting.id)
    assert updated_meeting.video_room_id == "NgPxrxVDQF8B"
    assert updated_meeting.meeting_url == @meeting_url
    assert updated_meeting.organizer_video_url == @meeting_url
    assert updated_meeting.attendee_video_url == @meeting_url
  end

  describe "a Meet on the booking's own Google event that cannot be read" do
    setup do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      calendar =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: "google-sub-1"
        )

      video =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: "google-sub-1",
          oauth_scope: "https://www.googleapis.com/auth/meetings.space.created",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_email: "guest@example.com",
          video_integration_id: video.id,
          calendar_integration_id: calendar.id,
          provider_event_id: "google-event-1"
        )

      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _meeting ->
        {:ok, %{integration_id: calendar.id, calendar_path: "primary"}}
      end)

      stub(Tymeslot.CalendarMock, :fetch_event, fn _ref, _context -> {:error, :rate_limited} end)

      %{meeting: meeting}
    end

    # Whether the event carries a Meet is unknown, so the room waits as it
    # waits for the event: no failure logged, and none counted towards the
    # recovery that announces the booking without a link at the fifth run.
    test "waits for it as for the event, quietly and without entering recovery", %{
      meeting: meeting
    } do
      args = %{"meeting_id" => meeting.id, "announce" => true}

      errors =
        capture_log([level: :error], fn ->
          assert :ok = perform_job(VideoRoomWorker, args, meta: %{"snoozed" => 4})
        end)

      assert errors == ""
      assert_enqueued(worker: VideoRoomWorker, args: args)
      refute_enqueued(worker: Tymeslot.Workers.EmailWorker)
      assert Repo.get!(MeetingSchema, meeting.id).video_room_id == nil
    end

    test "makes a Meet space of its own once the wait for the event is over", %{
      meeting: meeting
    } do
      booked_at = DateTime.utc_now() |> DateTime.add(-180, :second) |> DateTime.truncate(:second)
      meeting |> Changeset.change(inserted_at: booked_at) |> Repo.update!()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        space = %{"name" => "spaces/NgPxrxVDQF8B", "meetingUri" => @meeting_url}
        {:ok, %Req.Response{status: 200, body: Jason.encode!(space)}}
      end)

      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == "NgPxrxVDQF8B"
      assert updated.meeting_url == @meeting_url
    end
  end
end
