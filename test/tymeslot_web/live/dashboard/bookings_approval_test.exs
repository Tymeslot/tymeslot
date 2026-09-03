defmodule TymeslotWeb.Dashboard.BookingsApprovalTest do
  @moduledoc """
  Answering booking requests from the dashboard.

  The load-bearing test here is the ownership one: the buttons are rendered
  from a stream the host owns, but the event carries a meeting id from the
  client, and nothing about the markup stops that id being somebody else's.
  """

  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @moduletag :live
  @moduletag :bookings
  @moduletag :meetings

  alias Plug.Test
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)

    stub(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _client ->
      {{:ok, nil}, {:ok, nil}}
    end)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  defp held_meeting(user, attrs \\ %{}) do
    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      organizer_email: user.email,
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      start_time: DateTime.add(DateTime.utc_now(:second), 5, :day),
      end_time: DateTime.add(DateTime.utc_now(:second), 5 * 24 * 60 + 30, :minute),
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp open_requests(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    render_click(element(view, "button", "Requests"))
    view
  end

  # The buttons live in a LiveComponent, so a forged event has to be pushed at
  # that component rather than at the page — which is exactly what a crafted
  # client message would do.
  defp push_to_component(view, event, params) do
    view |> with_target("#bookings-management") |> render_click(event, params)
  end

  # The page chrome mentions "Reschedule" in its help panel, so the assertion
  # has to be scoped to the card or it passes for the wrong reason.
  defp card_html(view) do
    view |> element("#meetings > div") |> render()
  end

  describe "where a held request appears" do
    test "not among upcoming meetings", %{conn: conn, user: user} do
      held_meeting(user)

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings")

      # A request nobody has agreed to is not an upcoming meeting, and listing
      # it beside confirmed bookings is what made one look like the other.
      refute html =~ "Alex Guest"
    end

    test "under its own tab, labelled as unanswered", %{conn: conn, user: user} do
      held_meeting(user)

      card = card_html(open_requests(conn))

      assert card =~ "Alex Guest"
      assert card =~ "Awaiting your approval"
      refute card =~ "Scheduled"
    end

    test "a request whose slot has passed is not reported as completed", %{conn: conn, user: user} do
      # Between the start time passing and the expiry sweep running, the badge
      # is the only thing describing this booking. "Completed" would claim a
      # meeting happened that nobody ever agreed to.
      past = DateTime.add(DateTime.utc_now(:second), -2, :hour)

      held_meeting(user, %{
        start_time: past,
        end_time: DateTime.add(past, 30, :minute),
        approval_deadline_at: DateTime.add(past, 15, :minute)
      })

      card = card_html(open_requests(conn))

      assert card =~ "Awaiting your approval"
      refute card =~ "Completed"
    end

    test "the tab is hidden when a host has nothing to answer", %{conn: conn, user: user} do
      held_meeting(user, %{status: "confirmed", approval_deadline_at: nil})

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings")

      refute html =~ "Requests"
    end
  end

  describe "where a lapsed request appears" do
    test "not among upcoming meetings, even while its slot is still ahead", %{
      conn: conn,
      user: user
    } do
      # The window closed with nobody answering, but the meeting's own start
      # time can still be days away — "upcoming" has to read the resolved
      # status, not just the clock, or a lapsed request looks like a live
      # booking again.
      held_meeting(user, %{status: "expired", attendee_name: "Sam Overdue"})

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings")

      refute html =~ "Sam Overdue"
    end

    test "carries an honest badge once it falls into Past, not \"Scheduled\"", %{
      conn: conn,
      user: user
    } do
      past = DateTime.add(DateTime.utc_now(:second), -2, :hour)

      held_meeting(user, %{
        status: "expired",
        attendee_name: "Sam Overdue",
        start_time: past,
        end_time: DateTime.add(past, 30, :minute),
        approval_deadline_at: DateTime.add(past, 90, :minute)
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      render_click(element(view, "button", "Past"))
      card = card_html(view)

      assert card =~ "Sam Overdue"
      assert card =~ "Expired"
      refute card =~ "Scheduled"
    end
  end

  describe "an unpaid checkout is never shown as agreed" do
    test "an awaiting_payment booking is badged honestly, not as Scheduled",
         %{conn: conn, user: user} do
      insert(:meeting,
        status: "awaiting_payment",
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Unpaid Guest",
        start_time: DateTime.add(DateTime.utc_now(:second), 2, :day),
        end_time: DateTime.add(DateTime.utc_now(:second), 2 * 24 * 60 + 30, :minute)
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings")

      assert html =~ "Unpaid Guest"
      assert html =~ "Awaiting payment"
      refute html =~ "Scheduled"
    end
  end

  describe "the actions a held request offers" do
    test "approve and decline, not join, reschedule or cancel", %{conn: conn, user: user} do
      held_meeting(user)

      card = card_html(open_requests(conn))

      assert card =~ "data-testid=\"approve-request\""
      assert card =~ "data-testid=\"decline-request\""

      # Each of these presupposes a meeting that is happening.
      refute card =~ "Join Meeting"
      refute card =~ "Reschedule"
      refute card =~ "show_cancel_modal"
    end
  end

  describe "answering" do
    # `answer/4` runs the transition off the socket's process
    # (`start_async/3`), so every outcome here is only visible after
    # `render_async/2` observes the task finish. The default
    # `assert_receive_timeout` (100ms) is too tight for a cold DB
    # connection plus the calendar/video/notification fan-out the first
    # time this process touches them, so every call here is given an
    # explicit, more generous budget rather than relying on the default.
    test "approving confirms the booking", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      view |> element("[data-testid='approve-request']") |> render_click()
      render_async(view, 1000)

      assert reload(meeting).status == "confirmed"
    end

    # The transition and its calendar/video/notification fan-out run off the
    # socket's process, so the click's own render (captured before that task
    # completes) must show the row mid-flight, not skip straight to the
    # answered state. `:answering_request` set-then-cleared inside a single
    # synchronous handler can never be observed here.
    test "the approve button disables and shows a spinner while the answer is in flight",
         %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      html = view |> element("[data-testid='approve-request']") |> render_click()

      assert html =~ ~s(id="approve-request-#{meeting.id}")
      assert html =~ "disabled"

      render_async(view, 1000)
    end

    test "declining releases the slot and keeps the note", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      view |> element("[data-testid='decline-request']") |> render_click()

      view
      |> form("#decline-request-form", %{"reason" => "Away that week"})
      |> render_submit()

      render_async(view, 1000)

      stored = reload(meeting)
      assert stored.status == "cancelled"
      assert stored.decline_reason == "Away that week"
    end

    test "a decline reason that is not plain text does not crash the dashboard",
         %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      view |> element("[data-testid='decline-request']") |> render_click()

      # A crafted `reason[x]=y` field arrives as a map, not a string — no
      # ordinary textarea submission can produce this, only a forged frame.
      push_to_component(view, "confirm_decline_request", %{"reason" => %{"x" => "y"}})
      render_async(view, 1000)

      assert Process.alive?(view.pid)
      stored = reload(meeting)
      assert stored.status == "cancelled"
      assert stored.decline_reason == nil
    end

    test "a null byte in the decline reason is stripped rather than crashing the write",
         %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      view |> element("[data-testid='decline-request']") |> render_click()

      view
      |> form("#decline-request-form", %{"reason" => "Away\x00 that week"})
      |> render_submit()

      render_async(view, 1000)

      assert Process.alive?(view.pid)
      stored = reload(meeting)
      assert stored.status == "cancelled"
      refute stored.decline_reason =~ "\x00"
    end

    test "a request answered elsewhere is reported, not re-answered", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      {:ok, _declined} = Approval.decline(meeting, "Already handled")

      view |> element("[data-testid='approve-request']") |> render_click()
      render_async(view, 1000)

      # The decline stands; approving after it must not overwrite the answer.
      assert reload(meeting).status == "cancelled"
    end

    test "a request that lapsed while the page was open is reloaded, not left stale",
         %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      # The expiry sweep (or the emailed link) got there first, out of band —
      # the view still thinks the row is answerable.
      {:ok, _expired} = Approval.expire(meeting)

      push_to_component(view, "approve_request", %{"id" => meeting.id})
      render_async(view, 1000)

      # The flash is delivered to the parent LiveView via `send/2`, a
      # separate round trip from the click's own render.
      assert render(view) =~ "already been answered"
      # The row is stale either way: it must not keep offering an action on a
      # request that is no longer awaiting anything. The reload leaves no
      # meeting in the "awaiting_approval" filter at all, so the assertion is
      # against the whole page rather than `card_html/1`, which assumes
      # exactly one row is present.
      refute render(view) =~ "data-testid=\"approve-request\""
    end

    test "an id that is not a UUID is refused, not cast a second time",
         %{conn: conn, user: user} do
      held_meeting(user)
      view = open_requests(conn)

      push_to_component(view, "approve_request", %{"id" => "not-a-uuid"})

      assert render(view) =~ "could not be found"
    end
  end

  describe "rate limiting" do
    setup do
      RateLimiter.clear_all()
      :ok
    end

    test "approving is refused once the per-host limit is exhausted", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      for _i <- 1..20 do
        assert :ok = RateLimiter.check_meeting_approval_rate_limit("dashboard:#{user.id}")
      end

      view |> element("[data-testid='approve-request']") |> render_click()

      assert render(view) =~ "reached the limit"
      assert reload(meeting).status == "awaiting_approval"
    end

    test "declining is refused once the per-host limit is exhausted", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      view |> element("[data-testid='decline-request']") |> render_click()

      for _i <- 1..20 do
        assert :ok = RateLimiter.check_meeting_approval_rate_limit("dashboard:#{user.id}")
      end

      view
      |> form("#decline-request-form", %{"reason" => "Away that week"})
      |> render_submit()

      assert render(view) =~ "reached the limit"
      assert reload(meeting).status == "awaiting_approval"
    end
  end

  describe "answering somebody else's request" do
    test "an id belonging to another host is refused", %{conn: conn, user: user} do
      held_meeting(user)
      stranger = insert(:user)
      theirs = held_meeting(stranger)

      view = open_requests(conn)

      push_to_component(view, "approve_request", %{"id" => theirs.id})

      assert reload(theirs).status == "awaiting_approval"
    end

    test "and cannot be opened in the decline modal either", %{conn: conn, user: user} do
      held_meeting(user)
      theirs = held_meeting(insert(:user), %{attendee_email: "stranger@example.com"})

      view = open_requests(conn)

      html = push_to_component(view, "show_decline_modal", %{"id" => theirs.id})

      # Their invitee's address must not leak into this host's modal.
      refute html =~ "stranger@example.com"
    end

    test "the attendee cannot approve their own request, even signed in under the booking email",
         %{user: host} do
      attendee = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: attendee)
      meeting = held_meeting(host, %{attendee_email: attendee.email})

      attendee_conn =
        build_conn() |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(attendee)

      {:ok, view, _html} = live(attendee_conn, ~p"/dashboard/meetings")

      push_to_component(view, "approve_request", %{"id" => meeting.id})

      assert reload(meeting).status == "awaiting_approval"
    end

    test "the attendee cannot decline their own request either", %{user: host} do
      attendee = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: attendee)
      meeting = held_meeting(host, %{attendee_email: attendee.email})

      attendee_conn =
        build_conn() |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(attendee)

      {:ok, view, _html} = live(attendee_conn, ~p"/dashboard/meetings")

      html = push_to_component(view, "show_decline_modal", %{"id" => meeting.id})

      refute html =~ "confirm_decline_request"
      assert reload(meeting).status == "awaiting_approval"
    end
  end
end
