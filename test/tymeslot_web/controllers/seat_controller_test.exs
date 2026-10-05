defmodule TymeslotWeb.SeatControllerTest do
  # Uses the global ETS rate limiter; must not run concurrently.
  use TymeslotWeb.ConnCase, async: false
  @moduletag :controllers
  @moduletag :bookings

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Repo
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

    %{leaver: leaver, meeting: meeting, meeting_type: meeting_type}
  end

  # Both halves of the cancel link, so a test can hold them to the same page.
  defp get_and_post(conn, token) do
    {conn |> recycle() |> get(~p"/seat/#{token}/cancel"),
     conn |> recycle() |> post(~p"/seat/#{token}/cancel")}
  end

  defp shift_meeting!(meeting, start_offset_minutes) do
    start =
      DateTime.utc_now()
      |> DateTime.add(start_offset_minutes, :minute)
      |> DateTime.truncate(:second)

    meeting
    |> Changeset.change(%{start_time: start, end_time: DateTime.add(start, 30, :minute)})
    |> Repo.update!()
  end

  describe "GET /seat/:token/cancel — confirmation landing page (no mutation)" do
    test "shows the confirmation page without cancelling the seat", %{conn: conn, leaver: leaver} do
      conn = get(conn, ~p"/seat/#{leaver.management_token}/cancel")

      assert html_response(conn, 200) =~ "Cancel your spot?"
      assert {:ok, reloaded} = ParticipantQueries.get_by_token(leaver.management_token)
      assert reloaded.cancelled_at == nil
    end

    test "names where the meeting takes place", %{
      conn: conn,
      leaver: leaver,
      meeting: meeting
    } do
      meeting
      |> Changeset.change(%{location_kind: "custom", location: "Studio 4, 1 High Street"})
      |> Repo.update!()

      conn = get(conn, ~p"/seat/#{leaver.management_token}/cancel")

      assert html_response(conn, 200) =~ "Studio 4, 1 High Street"
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

    test "names where the meeting was to take place", %{
      conn: conn,
      leaver: leaver,
      meeting: meeting
    } do
      meeting
      |> Changeset.change(%{location_kind: "video", location: "Video Call"})
      |> Repo.update!()

      conn = post(conn, ~p"/seat/#{leaver.management_token}/cancel")

      assert html_response(conn, 200) =~ "Video Call"
    end

    test "an unknown token shows the invalid page", %{conn: conn} do
      conn = post(conn, ~p"/seat/nope-not-a-token/cancel")

      assert html_response(conn, 404) =~ "no longer valid"
    end
  end

  describe "a link that can no longer be used" do
    # The organiser cancelled the whole meeting: the participant's own row is
    # still live, so the old POST went ahead to "cancel" it, failed on the
    # cancelled meeting, and showed the cancelled page, which promises an
    # email that nothing sends. The GET said the link was no longer valid.
    test "a meeting the host cancelled gets the same page from GET and POST, with no promised email",
         %{conn: conn, leaver: leaver, meeting: meeting} do
      assert {:ok, %{status: "cancelled"}} = Cancel.execute(meeting, caller: :organizer)

      {get_conn, post_conn} = get_and_post(conn, leaver.management_token)

      for response <- [html_response(get_conn, 410), html_response(post_conn, 410)] do
        assert response =~ "This meeting has been cancelled"
        refute response =~ "A confirmation email is on its way"
        assert response =~ ~s(href="/test-organizer")
      end

      assert {:ok, %{cancelled_at: nil}} =
               ParticipantQueries.get_by_token(leaver.management_token)
    end

    test "a seat already given up gets the same page from GET and POST, with no promised email",
         %{conn: conn, leaver: leaver} do
      assert conn |> post(~p"/seat/#{leaver.management_token}/cancel") |> html_response(200) =~
               "A confirmation email is on its way"

      {get_conn, post_conn} = get_and_post(conn, leaver.management_token)

      for response <- [html_response(get_conn, 410), html_response(post_conn, 410)] do
        assert response =~ "This spot is already cancelled"
        refute response =~ "A confirmation email is on its way"
      end
    end

    # A spent link is a dead end only for the spot it named: the host's
    # booking page is still where a new time is picked.
    test "a spent cancel or reschedule link offers the host's booking page for a new time",
         %{conn: conn, leaver: leaver} do
      token = leaver.management_token
      assert conn |> post(~p"/seat/#{token}/cancel") |> html_response(200)

      responses = [
        conn |> recycle() |> get(~p"/seat/#{token}/cancel") |> html_response(410),
        conn |> recycle() |> get(~p"/seat/#{token}/reschedule") |> html_response(410)
      ]

      for response <- responses do
        assert response =~ ~s(data-testid="book-new-time")
        assert response =~ ~s(href="/test-organizer")
      end
    end

    test "an unknown link offers no booking page, since it names no host", %{conn: conn} do
      html = conn |> get(~p"/seat/nope-not-a-token/cancel") |> html_response(404)

      refute html =~ "book-new-time"
    end

    test "a meeting under way says it has started, not that it is too close to start",
         %{conn: conn, leaver: leaver, meeting: meeting} do
      shift_meeting!(meeting, -5)

      {get_conn, post_conn} = get_and_post(conn, leaver.management_token)

      for response <- [html_response(get_conn, 409), html_response(post_conn, 409)] do
        assert response =~ "This meeting has already started"
      end

      assert {:ok, %{cancelled_at: nil}} =
               ParticipantQueries.get_by_token(leaver.management_token)
    end

    test "a meeting that is over says it has taken place",
         %{conn: conn, leaver: leaver, meeting: meeting} do
      shift_meeting!(meeting, -120)

      {get_conn, post_conn} = get_and_post(conn, leaver.management_token)

      for response <- [html_response(get_conn, 409), html_response(post_conn, 409)] do
        assert response =~ "This meeting has already taken place"
        refute response =~ "This meeting has already started"
        assert response =~ ~s(data-testid="book-new-time")
      end

      assert {:ok, %{cancelled_at: nil}} =
               ParticipantQueries.get_by_token(leaver.management_token)
    end
  end

  describe "the participant's language" do
    test "a seat page is written in the language the participant booked in",
         %{conn: conn, leaver: leaver} do
      leaver |> Changeset.change(%{locale: "de"}) |> Repo.update!()

      html = conn |> get(~p"/seat/#{leaver.management_token}/cancel") |> html_response(200)

      assert html =~ "Ihren Platz stornieren?"
      assert html =~ ~s(lang="de")
    end

    test "an unknown link keeps the request's language", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "fr")
        |> get(~p"/seat/nope-not-a-token/cancel")
        |> html_response(404)

      refute html =~ "This link is no longer valid"
      assert html =~ ~s(lang="fr")
    end
  end

  describe "rate limiting" do
    test "too many requests from one address get the too-many-attempts page",
         %{conn: conn, leaver: leaver} do
      for _attempt <- 1..60 do
        assert conn
               |> recycle()
               |> get(~p"/seat/#{leaver.management_token}/cancel")
               |> html_response(200)
      end

      assert conn
             |> recycle()
             |> get(~p"/seat/#{leaver.management_token}/cancel")
             |> html_response(429) =~ "Too many attempts"
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

    # The type stopped taking group bookings: its meetings keep their seats
    # but take no moves, so the picker could only refuse on submit.
    test "a seat whose type is no longer a group type is told to cancel and book again",
         %{conn: conn, leaver: leaver, meeting_type: meeting_type} do
      meeting_type |> Changeset.change(%{max_participants: 1}) |> Repo.update!()

      html = conn |> get(~p"/seat/#{leaver.management_token}/reschedule") |> html_response(200)

      assert html =~ "This spot can&#39;t be moved"
      assert html =~ "Cancel it and book a new time instead"
      assert html =~ ~s(href="/seat/#{leaver.management_token}/cancel")
    end

    # Deleting a type nilifies `meeting_type_id` on its meetings; the seats
    # stand, but there is no booking page left to move them on.
    test "a seat whose type was deleted is told to cancel and book again",
         %{conn: conn, leaver: leaver, meeting_type: meeting_type} do
      Repo.delete!(meeting_type)

      html = conn |> get(~p"/seat/#{leaver.management_token}/reschedule") |> html_response(200)

      assert html =~ "This spot can&#39;t be moved"
      assert html =~ ~s(href="/seat/#{leaver.management_token}/cancel")
    end

    test "a meeting under way gets the cancel link's started page, not the picker",
         %{conn: conn, leaver: leaver, meeting: meeting} do
      shift_meeting!(meeting, -5)

      html = conn |> get(~p"/seat/#{leaver.management_token}/reschedule") |> html_response(409)

      assert html =~ "This meeting has already started"
    end

    test "a meeting that is over gets the cancel link's past page, not the picker",
         %{conn: conn, leaver: leaver, meeting: meeting} do
      shift_meeting!(meeting, -120)

      html = conn |> get(~p"/seat/#{leaver.management_token}/reschedule") |> html_response(409)

      assert html =~ "This meeting has already taken place"
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
