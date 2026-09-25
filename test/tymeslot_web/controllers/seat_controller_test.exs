defmodule TymeslotWeb.SeatControllerTest do
  # Uses the global ETS rate limiter; must not run concurrently.
  use TymeslotWeb.ConnCase, async: false
  @moduletag :controllers
  @moduletag :bookings

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")

    profile =
      insert(:profile, user: user, timezone: "America/New_York", username: "test-organizer")

    open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        is_active: true,
        max_participants: 2
      )

    meeting_params = %{
      date: Date.add(Date.utc_today(), 2),
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, meeting} =
      Create.execute(meeting_params, %{"name" => "Leaver", "email" => "leaver@example.com"})

    {:ok, _meeting} =
      Create.execute(meeting_params, %{"name" => "Stayer", "email" => "stayer@example.com"})

    leaver =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.find(&(&1.email == "leaver@example.com"))

    %{leaver: leaver, meeting_type: meeting_type}
  end

  describe "GET /seat/:token/cancel — confirmation landing page (no mutation)" do
    test "shows the confirmation page without cancelling the seat", %{conn: conn, leaver: leaver} do
      conn = get(conn, ~p"/seat/#{leaver.management_token}/cancel")

      assert html_response(conn, 200) =~ "Cancel your spot?"
      assert {:ok, reloaded} = ParticipantQueries.get_by_token(leaver.management_token)
      assert reloaded.cancelled_at == nil
    end

    test "an unknown token shows the invalid page", %{conn: conn} do
      conn = get(conn, ~p"/seat/nope-not-a-token/cancel")

      assert html_response(conn, 404) =~ "no longer valid"
    end
  end

  describe "POST /seat/:token/cancel — cancels the seat" do
    test "cancels the seat and shows the cancelled page", %{conn: conn, leaver: leaver} do
      conn = post(conn, ~p"/seat/#{leaver.management_token}/cancel")

      assert html_response(conn, 200) =~ "Your spot has been cancelled"
      assert {:ok, reloaded} = ParticipantQueries.get_by_token(leaver.management_token)
      assert %DateTime{} = reloaded.cancelled_at
    end

    test "an unknown token shows the invalid page", %{conn: conn} do
      conn = post(conn, ~p"/seat/nope-not-a-token/cancel")

      assert html_response(conn, 404) =~ "no longer valid"
    end
  end

  describe "GET /seat/:token/reschedule — bounces into the public booking picker" do
    test "redirects to the organiser's booking page for this meeting type, carrying the token",
         %{conn: conn, leaver: leaver} do
      conn = get(conn, ~p"/seat/#{leaver.management_token}/reschedule")

      assert %{status: 302} = conn

      assert redirected_to(conn) =~
               ~r{^/[^/]+/[^?]+\?reschedule_seat_token=#{leaver.management_token}$}
    end

    test "an unknown token shows the invalid page", %{conn: conn} do
      conn = get(conn, ~p"/seat/nope-not-a-token/reschedule")

      assert html_response(conn, 404) =~ "no longer valid"
    end

    # The picker resolves a meeting type by its effective slug, derived from
    # the name whenever no custom slug is set — which is the default. Sending
    # a duration-shaped identifier instead ("30min") resolved to nothing, so
    # every emailed reschedule link died on "Invalid meeting type".
    test "redirects to a path the booking picker actually resolves",
         %{conn: conn, leaver: leaver, meeting_type: meeting_type} do
      assert is_nil(meeting_type.slug), "this test is about the no-custom-slug default"

      conn = get(conn, ~p"/seat/#{leaver.management_token}/reschedule")
      target = redirected_to(conn)

      assert target =~ "/test-organizer/#{Slugs.effective_slug(meeting_type)}?"

      assert conn
             |> recycle()
             |> get(target)
             |> html_response(200)
    end
  end
end
