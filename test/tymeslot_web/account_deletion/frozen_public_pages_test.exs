defmodule TymeslotWeb.AccountDeletion.FrozenPublicPagesTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :bookings
  @moduletag :polls
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers, only: [insert_meeting_for_user: 1]
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Bookings.RescheduleSeat
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  defp freeze(user) do
    now = DateTime.utc_now(:second)
    {:ok, pending} = UserQueries.mark_deletion_scheduled(user, now, DateTime.add(now, 14, :day))
    pending
  end

  defp held_meeting(user) do
    insert(:meeting,
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    )
  end

  test "the booking page of a host pending deletion is a 404", %{conn: conn} do
    user = insert(:user)
    insert(:profile, user: user, username: "frozen-page")
    freeze(user)

    assert_error_sent(404, fn -> get(conn, "/frozen-page") end)
  end

  test "the free/busy feed and the .ics download of a host pending deletion are 404", %{
    conn: conn
  } do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "frozen-feed")
    {:ok, _profile} = ProfileQueries.update_freebusy_token(profile, "frozen-feed-token")
    meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)

    assert conn |> get("/free-busy/frozen-feed-token") |> response(200)
    freeze(user)

    assert conn |> get("/free-busy/frozen-feed-token") |> response(404)

    assert conn
           |> get("/frozen-feed/meeting/#{meeting.uid}/calendar.ics")
           |> response(404)
  end

  test "the cancel links of a host pending deletion are 404, not a redirect", %{conn: conn} do
    user = insert(:user)
    insert(:profile, user: user, username: "frozen-links")
    meeting = insert(:meeting, organizer_user: user, organizer_user_id: user.id)
    freeze(user)

    assert_raise TymeslotWeb.NotFoundError, fn ->
      live(conn, "/frozen-links/meeting/#{meeting.uid}/cancel")
    end

    assert_error_sent(404, fn -> get(conn, "/meeting/#{meeting.uid}/cancel") end)
  end

  describe "the booking request link in the host's email" do
    test "shows nothing of the request once the host's account is pending deletion",
         %{conn: conn} do
      user = insert(:user)
      meeting = held_meeting(user)
      path = "/meeting-request/" <> ApprovalToken.sign(meeting)

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Approve booking"

      freeze(user)

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Link not recognised"
      refute html =~ "Alex Guest"
      refute html =~ "Approve booking"
    end

    test "cannot be answered from a page opened before the freeze", %{conn: conn} do
      user = insert(:user)
      meeting = held_meeting(user)

      {:ok, view, _html} = live(conn, "/meeting-request/" <> ApprovalToken.sign(meeting))
      freeze(user)

      html = view |> element("[data-testid='approve-request']") |> render_click()

      assert html =~ "Link not recognised"
      refute html =~ "changed since"
      assert Repo.get!(MeetingSchema, meeting.id).status == "awaiting_approval"
    end
  end

  test "a booking for a host pending deletion is refused" do
    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    freeze(user)

    meeting_params = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id
    }

    form_data = %{"name" => "Guest", "email" => "guest@example.com", "message" => ""}

    assert Create.execute(meeting_params, form_data, skip_calendar_check: true) ==
             {:error, :host_not_found}
  end

  test "an RSVP link of a host pending deletion behaves as unknown" do
    user = insert(:user)
    meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)
    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
    freeze(user)

    assert Guests.get_open_invitation(guest.rsvp_token) == {:error, :not_found}
  end

  test "a reschedule submitted from a page opened before the freeze is refused" do
    TestMocks.setup_email_mocks()
    TestMocks.stub_no_calendar_events()
    %{user: user} = create_always_bookable_profile(timezone: "Etc/UTC")
    meeting = insert_meeting_for_user(user)
    freeze(user)

    new_params = %{
      date: Date.to_string(next_bookable_weekday(5)),
      time: "10:00 AM",
      duration: "60min",
      user_timezone: "Etc/UTC"
    }

    assert Reschedule.execute(meeting.uid, new_params, user.id) ==
             {:error, :meeting_not_found}

    assert {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
    assert DateTime.compare(unchanged.start_time, meeting.start_time) == :eq
  end

  describe "the poll voting link of a host pending deletion" do
    setup %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("1", "frozen-poll", "Etc/UTC")
      poll = insert(:poll, user: user, title: "Frozen poll")
      slot = insert(:poll_time_slot, poll: poll)
      path = "/#{profile.username}/poll/#{poll.token}"

      {:ok, view, html} = live(conn, path)
      assert html =~ "Frozen poll"

      %{user: user, poll: poll, slot: slot, view: view, path: path}
    end

    test "answers as if the poll did not exist", %{conn: conn, user: user, poll: poll, path: path} do
      assert {:ok, _poll} = Polls.get_poll_for_voting(poll.token)
      freeze(user)

      assert Polls.get_poll_for_voting(poll.token) == {:error, :not_found}
      assert_error_sent(404, fn -> get(conn, path) end)
    end

    test "takes no registration from a page opened before the freeze",
         %{user: user, poll: poll, view: view} do
      freeze(user)

      html =
        view
        |> form("form[data-testid='poll-register-form']", %{
          "name" => "Ada Lovelace",
          "email" => "ada@example.com"
        })
        |> render_submit()

      assert html =~ "Voting has closed for this poll."
      assert PollParticipantQueries.count_for_poll(poll.id) == 0
    end

    test "takes no votes from a page opened before the freeze",
         %{user: user, poll: poll, slot: slot, view: view} do
      view
      |> form("form[data-testid='poll-register-form']", %{
        "name" => "Grace",
        "email" => "grace@example.com"
      })
      |> render_submit()

      freeze(user)

      html =
        view
        |> form("form[data-testid='poll-vote-form']", %{"votes" => %{slot.id => "yes"}})
        |> render_submit()

      assert html =~ "Voting has closed for this poll."
      assert %{voted_at: nil} = Repo.get_by!(PollParticipantSchema, poll_id: poll.id)
    end
  end

  describe "a group booking seat link of a host pending deletion" do
    setup do
      user = insert(:user)
      insert(:profile, user: user)

      start = DateTime.add(DateTime.utc_now(:second), 2, :day)

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          organizer_email: user.email,
          start_time: start,
          end_time: DateTime.add(start, 30, :minute)
        )

      %{user: user, seat: insert(:participant, meeting: meeting)}
    end

    test "cancel link shows the invalid page and leaves the seat alone",
         %{conn: conn, user: user, seat: seat} do
      path = "/seat/#{seat.management_token}/cancel"
      assert conn |> get(path) |> html_response(200)

      freeze(user)

      assert conn |> recycle() |> get(path) |> html_response(404) =~ "no longer valid"
      assert conn |> recycle() |> post(path) |> html_response(404) =~ "no longer valid"
      assert {:ok, %{cancelled_at: nil}} = ParticipantQueries.get_by_token(seat.management_token)
    end

    test "a move submitted from a booking page opened before the freeze is refused",
         %{user: user, seat: seat} do
      freeze(user)

      params = %{
        date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
        time: "10:00",
        duration: "30min",
        user_timezone: "Etc/UTC"
      }

      assert RescheduleSeat.execute(seat.management_token, params, user.id) ==
               {:error, :meeting_not_found}

      assert {:ok, %{cancelled_at: nil, meeting_id: meeting_id}} =
               ParticipantQueries.get_by_token(seat.management_token)

      assert meeting_id == seat.meeting_id
    end
  end
end
