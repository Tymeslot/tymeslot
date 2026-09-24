defmodule Tymeslot.Bookings.TeamsBookingLinksTest do
  @moduledoc """
  The attendee's journey from a Microsoft Teams booking to its cancel and
  reschedule pages.

  A booking's cancel and reschedule links are built from its `uid` when it is
  made, stored on the meeting and emailed to the attendee. Attaching the Teams
  room used to replace that `uid` with the room's Graph event id, so both links
  landed on "Meeting not found" from then on (#143). This walks the whole
  path: the public booking, the video room job, then each stored link opened
  as the attendee would.
  """

  # Not async: room creation runs through the application-wide Teams circuit
  # breaker, which DataCase resets only between non-async modules.
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.ThemeMeetingTestCases, only: [test_reschedule_page_navigation: 4]

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  setup do
    # No booking calendar, so the Teams meeting gets an event of its own.
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    user = insert(:user, name: "Teams Host")

    profile =
      insert(:profile,
        user: user,
        username: "teams-links",
        booking_theme: "1",
        timezone: "Europe/London"
      )

    _schedule = open_schedule_for(profile)

    teams =
      insert(:video_integration,
        user: user,
        name: "Teams",
        provider: "teams",
        base_url: nil,
        api_key_encrypted: nil,
        access_token_encrypted: Encryption.encrypt("graph-access-token"),
        refresh_token_encrypted: Encryption.encrypt("graph-refresh-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
        provider_account_id: "entra-oid-organiser"
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Teams Consultation",
        duration_minutes: 30,
        is_active: true,
        allow_video: true,
        video_integration_id: teams.id
      )

    stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    # Graph names the room's event with an id that is not a UUID, as it
    # always does.
    stub(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok,
       %Req.Response{
         status: 201,
         body:
           Jason.encode!(%{
             "id" => "AAMkAGI2TG93AAA=",
             "onlineMeeting" => %{
               "joinUrl" => "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc"
             }
           })
       }}
    end)

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  test "the stored cancel and reschedule links open the booking once its Teams room exists",
       %{conn: conn, user: user, profile: profile, meeting_type: meeting_type} do
    meeting = book_with_teams_room(user, meeting_type)

    assert meeting.video_room_id == "AAMkAGI2TG93AAA="

    assert URI.parse(meeting.cancel_url).path ==
             "/#{profile.username}/meeting/#{meeting.uid}/cancel"

    # The reschedule link opens this booking's reschedule page, whose next step
    # carries this booking's uid.
    {:ok, reschedule_view, _html} = live(conn, URI.parse(meeting.reschedule_url).path)
    assert render(reschedule_view) =~ "Reschedule Appointment"

    test_reschedule_page_navigation(
      reschedule_view,
      "Choose New Time",
      profile.username,
      meeting.uid
    )

    # The cancel link opens this booking's cancel page, and cancelling there
    # cancels this booking.
    {:ok, cancel_view, _html} = live(conn, URI.parse(meeting.cancel_url).path)
    assert has_element?(cancel_view, "[data-testid='cancel-meeting']")

    assert {:error, {:redirect, %{to: to}}} =
             cancel_view
             |> element("[data-testid='cancel-meeting']")
             |> render_click()

    assert to =~ "/meeting/#{meeting.uid}/cancel-confirmed"
    assert Repo.get!(MeetingSchema, meeting.id).status == "cancelled"
  end

  # Books through the public booking path, which builds the stored links from
  # the booking's uid, then runs the room job the booking enqueued.
  defp book_with_teams_room(user, meeting_type) do
    params = %{
      form_data: %{"name" => "Ada Attendee", "email" => "ada@example.com", "message" => ""},
      meeting_params: %{
        date: Date.add(Date.utc_today(), 2),
        time: "14:00",
        duration: "30min",
        user_timezone: "Europe/London",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        with_video_room: true
      }
    }

    assert {:ok, booked} = Orchestrator.submit_booking(params, organizer_user_id: user.id)

    assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => booked.id})
    assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => booked.id, "announce" => true})

    meeting = Repo.get!(MeetingSchema, booked.id)
    assert meeting.uid == booked.uid
    meeting
  end
end
