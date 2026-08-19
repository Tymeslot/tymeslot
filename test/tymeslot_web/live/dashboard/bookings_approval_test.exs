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
    test "approving confirms the booking", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      view |> element("[data-testid='approve-request']") |> render_click()

      assert reload(meeting).status == "confirmed"
    end

    test "declining releases the slot and keeps the note", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      view |> element("[data-testid='decline-request']") |> render_click()

      view
      |> form("#decline-request-form", %{"reason" => "Away that week"})
      |> render_submit()

      stored = reload(meeting)
      assert stored.status == "cancelled"
      assert stored.decline_reason == "Away that week"
    end

    test "a request answered elsewhere is reported, not re-answered", %{conn: conn, user: user} do
      meeting = held_meeting(user)
      view = open_requests(conn)

      {:ok, _declined} = Approval.decline(meeting, "Already handled")

      view |> element("[data-testid='approve-request']") |> render_click()

      # The decline stands; approving after it must not overwrite the answer.
      assert reload(meeting).status == "cancelled"
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
  end
end
