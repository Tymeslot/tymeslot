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
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  @moduletag :live
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup do
    # Every mount in this file resolves the same loopback client_ip, so a
    # test that saturates the approval bucket must not bleed into the next.
    RateLimiter.clear_all()
    :ok
  end

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

  # A held request on a gated meeting type, owned by a host who is bookable at
  # any hour — so the invitee can actually move it, which returns it to the
  # gate as a new request (`Tymeslot.Bookings.Reschedule`).
  defp movable_request(attrs \\ %{}) do
    %{user: user} = create_always_bookable_profile()

    meeting_type =
      insert(:meeting_type,
        user: user,
        user_id: user.id,
        requires_approval: true,
        approval_window_hours: 12
      )

    meeting =
      held_meeting(
        Map.merge(
          %{
            organizer_user: user,
            organizer_user_id: user.id,
            meeting_type_id: meeting_type.id,
            # Made an hour ago: the host is reading the email later, and the
            # re-request the invitee is about to make must land on a visibly
            # different `approval_requested_at` (both are truncated to the
            # second, and this test moves faster than that).
            approval_requested_at: DateTime.add(DateTime.utc_now(:second), -1, :hour),
            approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 11, :hour)
          },
          attrs
        )
      )

    %{user: user, meeting: meeting}
  end

  defp reschedule_params do
    %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }
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

    test "shows the host's own timezone rather than the invitee's", %{conn: conn} do
      # No profile is inserted for the host, so `Profiles.get_user_timezone/1`
      # falls back to "Europe/Tallinn" — distinct from the invitee's
      # "America/New_York" set by the meeting factory, so the two cannot be
      # confused for each other in the assertion below.
      meeting = held_meeting(%{attendee_timezone: "America/New_York"})

      {:ok, _view, html} = live(conn, request_path(meeting))

      assert html =~ "Europe/Tallinn"
      refute html =~ "America/New_York"
    end
  end

  describe "a lapsed but unswept request" do
    test "is shown as no longer answerable rather than as still open", %{conn: conn} do
      meeting =
        held_meeting(%{
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)
        })

      {:ok, _view, html} = live(conn, request_path(meeting))

      assert html =~ "Deadline passed"
      refute html =~ "Approve booking"
      refute html =~ "this request lapses"

      # Purely a rendering fix: the row itself is still whatever the sweep
      # job left it as.
      assert reload(meeting).status == "awaiting_approval"
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

    test "the outcome badge renders the heroicon rather than nesting one svg inside another",
         %{conn: conn} do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting))

      html = view |> element("[data-testid='approve-request']") |> render_click()

      # `<.icon_badge>` draws its own `<svg>` wrapper around whatever it is
      # given; passing it an `<.icon>` (which renders a complete `<svg>` of
      # its own) used to nest one svg inside another instead of drawing the
      # heroicon's path, so the badge painted empty.
      refute html =~ ~r/<svg[^>]*><svg/
      assert html =~ ~r/<svg[^>]*text-white[^>]*><path/
    end

    test "declining releases the slot and keeps the reason", %{conn: conn} do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting, "?intent=decline"))

      assert view
             |> form("#decline-request-form", %{"reason" => "Away that week"})
             |> render_submit() =~ "Booking declined"

      stored = reload(meeting)
      assert stored.status == "cancelled"
      assert stored.decline_reason == "Away that week"
    end

    test "a NUL byte in the decline reason does not crash the page", %{conn: conn} do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting, "?intent=decline"))

      assert view
             |> form("#decline-request-form", %{"reason" => "Away\x00 that week"})
             |> render_submit() =~ "Booking declined"

      assert reload(meeting).decline_reason == "Away that week"
    end

    test "a request the invitee re-timed is not answered from the copy on screen",
         %{conn: conn} do
      %{user: user, meeting: meeting} = movable_request()

      {:ok, view, html} = live(conn, request_path(meeting))
      assert html =~ "Approve booking"

      # The invitee moves the still-held request while the host reads the
      # email. On a gated meeting type that is a brand new request: a fresh
      # `approval_requested_at`, a fresh deadline, and above all a different
      # time from the one rendered on the host's page.
      {:ok, rerequested} =
        Reschedule.execute(meeting.uid, reschedule_params(), %{}, user.id)

      assert rerequested.start_time != meeting.start_time

      html = view |> element("[data-testid='approve-request']") |> render_click()

      # The guarded transition only tests the status, so without the answer
      # path re-checking the token the host would confirm a time they have
      # never been shown.
      assert html =~ "Link not recognised"
      assert render(view) =~ "changed since this page was opened"

      stored = reload(meeting)
      assert stored.status == "awaiting_approval"
      assert DateTime.compare(stored.start_time, rerequested.start_time) == :eq
    end

    test "the old request's lapsed deadline does not expire the new live one",
         %{conn: conn} do
      # The host's page was rendered while the first request's deadline was
      # still ahead; by the time they click, that deadline has passed and the
      # invitee has re-requested a different time with a window of its own.
      # `Approval.approve/1` releases a request answered past its deadline, so
      # answering the stale copy would expire the live request the host was
      # never asked about.
      %{user: user, meeting: meeting} =
        movable_request(%{
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :minute)
        })

      {:ok, view, _html} = live(conn, request_path(meeting))

      {:ok, rerequested} = Reschedule.execute(meeting.uid, reschedule_params(), %{}, user.id)
      assert rerequested.status == "awaiting_approval"

      # Dispatched directly, as the older DOM the host is looking at would:
      # the page itself now renders the lapsed state, without the button.
      render_click(view, "approve", %{})

      stored = reload(meeting)
      assert stored.status == "awaiting_approval"
      assert is_nil(stored.approval_resolved_at)
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

  describe "answering is rate-limited" do
    test "the mount captures a real client_ip rather than falling back to unknown", %{
      conn: conn
    } do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting))

      # Without `TymeslotWeb.Hooks.ClientInfoHook` in the route's
      # `live_session`, every visitor resolves to the literal "unknown" and
      # the rate limiter below shares one bucket across the whole instance.
      client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip]

      assert is_binary(client_ip) and byte_size(client_ip) > 0
      assert client_ip != "unknown"
    end

    test "too many answers from the same client flash the limiter's message instead of acting", %{
      conn: conn
    } do
      meeting = held_meeting()

      {:ok, view, _html} = live(conn, request_path(meeting))

      client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip]
      Enum.each(1..20, fn _i -> RateLimiter.check_meeting_approval_rate_limit(client_ip) end)

      html = view |> element("[data-testid='approve-request']") |> render_click()

      assert html =~ "Too many attempts"
      assert reload(meeting).status == "awaiting_approval"
    end
  end

  describe "links that should not work" do
    test "a token that is not ours is refused", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/meeting-request/not-a-real-token")

      assert html =~ "Link not recognised"
    end

    test "approving from an unrecognised link does not crash the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meeting-request/not-a-real-token")

      # There is no held meeting to act on; sending the "approve" event
      # directly (bypassing the rendered buttons, which is what an attacker
      # replaying the phx event would do) must not raise.
      html = render_click(view, "approve", %{})

      assert html =~ "Link not recognised"
    end

    test "a request the invitee withdrew is not shown as declined by the host", %{conn: conn} do
      meeting = held_meeting(%{status: "cancelled"})

      {:ok, _view, html} = live(conn, request_path(meeting))

      refute html =~ "Booking declined"
      refute html =~ "has been told"
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

    test "a meeting the host approved and then cancelled is not shown as declined",
         %{conn: conn} do
      # Approving stamps `approval_resolved_at`, and an ordinary cancellation
      # afterwards leaves it in place. Reading that as "the host refused you"
      # would tell the invitee the opposite of what happened: their meeting was
      # agreed to and then called off.
      meeting = held_meeting()
      {:ok, approved} = Approval.approve(meeting)

      approved
      |> Changeset.change(status: "cancelled", cancelled_at: DateTime.utc_now(:second))
      |> Repo.update!()

      {:ok, _view, html} = live(conn, request_path(meeting))

      refute html =~ "Booking declined"
      assert html =~ "Link not recognised"
    end
  end
end
