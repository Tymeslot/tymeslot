defmodule TymeslotWeb.MeetingRequestLiveTest do
  @moduledoc """
  The page a host answers a booking request on.

  The most important test here is the one asserting that loading the page
  changes nothing. A mail security scanner following the link in an inbound
  message must not be able to answer on the host's behalf, and that guarantee
  is invisible in the code — it lives in the absence of any mutation in
  `mount/3`.
  """

  use TymeslotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  @moduletag :live
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      attendee_message: "Hoping to talk about Q4.",
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp request_path(meeting, query \\ "") do
    "/meeting-request/" <> ApprovalToken.sign(meeting) <> query
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  describe "loading the page" do
    test "shows the request without deciding anything", %{conn: conn} do
      meeting = held_meeting()

      {:ok, _view, html} = live(conn, request_path(meeting))

      assert html =~ "Alex Guest"
      assert html =~ "Hoping to talk about Q4."
      assert html =~ "Approve booking"

      # The whole point: a crawler that fetched this URL has not answered.
      assert reload(meeting).status == "awaiting_approval"
    end

    test "the decline intent still decides nothing", %{conn: conn} do
      meeting = held_meeting()

      {:ok, _view, html} = live(conn, request_path(meeting, "?intent=decline"))

      assert html =~ "Decline booking"
      assert reload(meeting).status == "awaiting_approval"
    end

    test "warns what happens if the host does not answer", %{conn: conn} do
      {:ok, _view, html} = live(conn, request_path(held_meeting()))

      assert html =~ "this request lapses"
    end
  end

  describe "answering" do
    test "approving confirms the booking", %{conn: conn} do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting))

      assert view |> element("[data-testid='approve-request']") |> render_click() =~
               "Booking confirmed"

      assert reload(meeting).status == "confirmed"
    end

    test "declining releases the slot and keeps the reason", %{conn: conn} do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting, "?intent=decline"))

      view
      |> form("form", %{"reason" => "Away that week"})
      |> render_change()

      assert view |> element("[data-testid='decline-request']") |> render_click() =~
               "Booking declined"

      stored = reload(meeting)
      assert stored.status == "cancelled"
      assert stored.decline_reason == "Away that week"
    end

    test "a request answered elsewhere reports what actually happened", %{conn: conn} do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting))

      # The host answered in another tab between page load and click.
      {:ok, _confirmed} = Approval.approve(meeting)

      html = view |> element("[data-testid='approve-request']") |> render_click()

      assert html =~ "Booking confirmed"
      assert render(view) =~ "already been answered"
    end
  end

  describe "links that should not work" do
    test "a token that is not ours is refused", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meeting-request/not-a-real-token")

      assert html =~ "Link not recognised"
    end

    test "a token whose meeting has changed hands is refused", %{conn: conn} do
      meeting = held_meeting()
      token_path = request_path(meeting)

      # Re-pointing the meeting at a different account invalidates a link
      # issued for the previous owner.
      other = insert(:user)
      meeting |> Changeset.change(organizer_user_id: other.id) |> Repo.update!()

      {:ok, _view, html} = live(conn, token_path)

      assert html =~ "Link not recognised"
    end

    test "an already-declined request shows its outcome rather than the buttons", %{conn: conn} do
      meeting = held_meeting()
      {:ok, _declined} = Approval.decline(meeting, "No thanks")

      {:ok, _view, html} = live(conn, request_path(meeting))

      assert html =~ "Booking declined"
      refute html =~ "Approve booking"
    end
  end
end
