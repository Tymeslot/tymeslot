defmodule TymeslotWeb.BookingVerificationLiveTest do
  @moduledoc """
  The page an attendee confirms a held booking on.

  The most important tests here assert that loading the page changes nothing:
  a mail security scanner following the link must neither confirm the booking
  nor release it. That guarantee lives in the absence of any mutation on GET.
  """

  # async: false: the failed-confirmation case patches Oban.insert/1 with
  # :meck, which replaces the module for every process.
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  @moduletag :live
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Invitations
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.WebhookWorker
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  setup do
    # Every mount here resolves the same loopback client_ip, so a test that
    # saturates the bucket must not bleed into the next.
    RateLimiter.clear_all()
    TestMocks.stub_no_calendar_events()

    user = insert(:user)
    insert(:profile, user: user, username: "verify-host")
    type = insert(:meeting_type, user: user, slug: "intro")

    %{user: user, type: type}
  end

  defp held(user, type, attrs \\ []) do
    insert(
      :awaiting_verification_meeting,
      Keyword.merge(
        [
          organizer_user_id: user.id,
          organizer_email: user.email,
          organizer_name: "Robin Host",
          meeting_type_id: type.id,
          title: "Intro call",
          video_integration_id: nil
        ],
        attrs
      )
    )
  end

  defp path(meeting), do: "/verify-booking/" <> EmailVerificationToken.sign(meeting)

  defp reload(%ParticipantSchema{id: id}), do: Repo.get!(ParticipantSchema, id)
  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp in_minutes(minutes), do: DateTime.add(DateTime.utc_now(:second), minutes, :minute)

  # A group slot held for verification, with one held seat booked from
  # Tokyo. The slot's own deadline is only a hiding marker; the seat's is the
  # one the page must read.
  defp held_seat(user, seat_deadline, slot_attrs \\ []) do
    type =
      insert(:meeting_type,
        user: user,
        slug: "workshop",
        max_participants: 3,
        requires_email_verification: true
      )

    slot =
      insert(
        :group_meeting,
        Keyword.merge(
          [
            status: :awaiting_verification,
            verification_deadline_at: in_minutes(30),
            organizer_user_id: user.id,
            organizer_email: user.email,
            organizer_name: "Robin Host",
            meeting_type_id: type.id,
            title: "Workshop",
            capacity: 3,
            video_integration_id: nil
          ],
          slot_attrs
        )
      )

    seat =
      insert(:participant,
        meeting: slot,
        email: "seat@example.com",
        timezone: "Asia/Tokyo",
        verification_deadline_at: seat_deadline
      )

    {slot, seat}
  end

  defp seat_path(seat), do: "/verify-booking/" <> EmailVerificationToken.sign_seat(seat)

  defp confirm(view), do: view |> element("[data-testid='confirm-booking']") |> render_click()

  describe "loading the page" do
    test "loading the link does not confirm the booking", %{conn: conn, user: user, type: type} do
      meeting = held(user, type)

      static = conn |> get(path(meeting)) |> html_response(200)
      assert static =~ "Checking your link…"
      refute static =~ "This link is not valid"
      refute static =~ "confirm-booking"

      {:ok, view, _html} = live(conn, path(meeting))

      assert has_element?(view, "[data-testid='confirm-booking']")
      assert render(view) =~ "Intro call"
      assert render(view) =~ "Robin Host"
      assert render(view) =~ "Your booking is held until"

      assert %{status: :awaiting_verification, email_verified_at: nil} = reload(meeting)
      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_confirmation_emails"})
    end

    # The booking pages keep their language apart from the app surface this
    # route resolves, so the page follows the language the booking was made
    # in, as the email that linked here does.
    test "the page speaks the booking's language", %{conn: conn, user: user, type: type} do
      meeting = held(user, type, attendee_locale: "de")

      {:ok, view, _html} = live(conn, path(meeting))

      assert render(view) =~ "Ihre Buchung ist bis"
      refute render(view) =~ "Your booking is held until"
      assert has_element?(view, "[data-testid='confirm-booking']", "Buchung bestätigen")
      # Screen readers take the language from the markup, and the root
      # layout's <html lang> is fixed before the token is read.
      assert has_element?(view, "div[lang='de']")
    end

    test "a tampered or stale token is invalid", %{conn: conn, user: user, type: type} do
      {:ok, view, _html} = live(conn, "/verify-booking/not-a-real-token")
      assert render(view) =~ "This link is not valid"
      refute has_element?(view, "[data-testid='confirm-booking']")

      meeting = held(user, type)
      stale_path = path(meeting)

      meeting
      |> Changeset.change(
        verification_deadline_at: DateTime.add(meeting.verification_deadline_at, 5, :minute)
      )
      |> Repo.update!()

      {:ok, view, _html} = live(conn, stale_path)
      assert render(view) =~ "This link is not valid"
      refute has_element?(view, "[data-testid='confirm-booking']")
    end

    test "an expired link offers a way back", %{conn: conn, user: user, type: type} do
      meeting =
        held(user, type,
          verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :minute)
        )

      {:ok, view, _html} = live(conn, path(meeting))

      assert render(view) =~ "This booking has expired"
      # The hold may have been shorter than 30 minutes, or ended for another
      # reason, so the card promises no length.
      assert render(view) =~ "This booking is no longer available, so the time was released."
      refute render(view) =~ "30 minutes"
      assert has_element?(view, "[data-testid='rebook-link'][href='/verify-host/intro']")
      refute has_element?(view, "[data-testid='confirm-booking']")
    end

    test "an expired hold that still holds its invitation links back without it", %{
      conn: conn,
      user: user
    } do
      type = insert(:meeting_type, user: user, slug: "by-invite", invitation_only: true)
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      # Past the deadline, but the expiry job has not run yet.
      meeting =
        held(user, type,
          invitation_id: invitation.id,
          verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :minute)
        )

      {:ok, view, _html} = live(conn, path(meeting))

      assert render(view) =~ "This booking has expired"
      assert has_element?(view, "[data-testid='rebook-link'][href='/verify-host/by-invite']")
      refute render(view) =~ invitation.token
    end

    test "a booking verified and later cancelled shows the invalid card", %{
      conn: conn,
      user: user,
      type: type
    } do
      meeting =
        held(user, type,
          status: :cancelled,
          email_verified_at: DateTime.utc_now(:second),
          cancelled_at: DateTime.utc_now(:second)
        )

      {:ok, view, _html} = live(conn, path(meeting))

      assert render(view) =~ "This link is not valid"
      refute render(view) =~ "This booking is already confirmed"
    end
  end

  describe "confirming" do
    test "confirming verifies the booking", %{conn: conn, user: user, type: type} do
      meeting = held(user, type)
      {:ok, view, _html} = live(conn, path(meeting))

      assert confirm(view) =~ "Your booking is confirmed"
      assert %{status: :confirmed, email_verified_at: %DateTime{}} = reload(meeting)
    end

    test "confirming on an approval type says the request was sent", %{conn: conn, user: user} do
      type = insert(:meeting_type, user: user, requires_approval: true, approval_window_hours: 24)
      meeting = held(user, type)
      {:ok, view, _html} = live(conn, path(meeting))

      html = confirm(view)

      assert html =~ "Your request has been sent"
      assert html =~ "Robin Host will confirm or decline it."
      assert reload(meeting).status == :awaiting_approval
    end

    test "a second confirmation says it is already confirmed", %{
      conn: conn,
      user: user,
      type: type
    } do
      meeting =
        held(user, type, status: :confirmed, email_verified_at: DateTime.utc_now(:second))

      {:ok, view, _html} = live(conn, path(meeting))

      assert render(view) =~ "This booking is already confirmed"
      refute has_element?(view, "[data-testid='confirm-booking']")
    end

    test "a confirmation after the deadline releases the slot", %{
      conn: conn,
      user: user,
      type: type
    } do
      meeting = held(user, type)
      {:ok, view, _html} = live(conn, path(meeting))

      freeze_clock(DateTime.add(meeting.verification_deadline_at, 1, :minute))

      assert confirm(view) =~ "This booking has expired"
      assert reload(meeting).status == :expired
    end

    # The page that held the slot is not the one that books it now, so the
    # attendee is told the time was released and sent back to book a series.
    test "a confirmation after the type became series-only releases the slot", %{
      conn: conn,
      user: user,
      type: type
    } do
      meeting = held(user, type)
      {:ok, view, _html} = live(conn, path(meeting))

      type
      |> Changeset.change(
        series_mode: :recurring,
        series_frequency: :weekly,
        series_interval: 1,
        series_min_occurrences: 2,
        series_max_occurrences: 12,
        series_required: true
      )
      |> Repo.update!()

      html = confirm(view)

      assert html =~ "This booking is no longer available, so the time was released."
      assert has_element?(view, "[data-testid='rebook-link'][href='/verify-host/intro']")
      assert %{status: :expired, email_verified_at: nil} = reload(meeting)
    end

    test "a confirmation that could not be scheduled can be tried again", %{
      conn: conn,
      user: user,
      type: type
    } do
      meeting = held(user, type)
      {:ok, view, _html} = live(conn, path(meeting))

      html = refusing_confirmation(fn -> quietly(fn -> confirm(view) end) end)

      assert html =~ "We could not confirm your booking just now."
      assert has_element?(view, "[data-testid='confirm-booking']")
      assert reload(meeting).status == :awaiting_verification

      assert confirm(view) =~ "Your booking is confirmed"
    end

    test "the confirm action is rate limited", %{conn: conn, user: user, type: type} do
      meeting = held(user, type)
      {:ok, view, _html} = live(conn, path(meeting))

      client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip]
      assert is_binary(client_ip) and client_ip != "unknown"
      Enum.each(1..20, fn _i -> RateLimiter.check(:booking_email_verification, client_ip) end)

      assert confirm(view) =~ "Too many attempts"

      assert view |> element("[data-testid='release-booking']") |> render_click() =~
               "Too many attempts"

      assert %{status: :awaiting_verification, email_verified_at: nil} = reload(meeting)
    end
  end

  describe "I didn't make this booking" do
    test "releases the slot and sends nothing", %{conn: conn, user: user, type: type} do
      # Subscribed, so a release that announced anything would enqueue here.
      insert(:webhook, user: user, events: ["meeting.created", "meeting.cancelled"])
      meeting = held(user, type)

      assert conn |> get(path(meeting)) |> html_response(200)
      {:ok, view, _html} = live(conn, path(meeting))
      assert reload(meeting).status == :awaiting_verification

      html = view |> element("[data-testid='release-booking']") |> render_click()

      assert html =~ "The booking was cancelled and the time released."
      assert %{status: :cancelled, email_verified_at: nil} = reload(meeting)
      refute_enqueued(worker: EmailWorker)
      refute_enqueued(worker: WebhookWorker)
      refute_enqueued(worker: CalendarEventWorker)
    end

    test "reloading after a release shows the released card", %{
      conn: conn,
      user: user,
      type: type
    } do
      meeting = held(user, type)
      {:ok, view, _html} = live(conn, path(meeting))
      view |> element("[data-testid='release-booking']") |> render_click()

      {:ok, reloaded, _html} = live(conn, path(meeting))

      assert render(reloaded) =~ "The booking was cancelled and the time released."
      refute has_element?(reloaded, "[data-testid='confirm-booking']")
    end
  end

  describe "a seat on a group meeting" do
    setup do
      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
        {:error, :no_integration}
      end)

      :ok
    end

    test "loading a seat link does not confirm it", %{conn: conn, user: user} do
      # The slot's marker has passed while the seat's own hold has not, so a
      # page reading the slot's deadline would call the link expired.
      {slot, seat} = held_seat(user, in_minutes(20), verification_deadline_at: in_minutes(-5))

      static = conn |> get(seat_path(seat)) |> html_response(200)
      refute static =~ "confirm-booking"

      {:ok, view, _html} = live(conn, seat_path(seat))

      assert has_element?(view, "[data-testid='confirm-booking']")
      html = render(view)
      assert html =~ "Workshop"
      assert html =~ "JST"

      assert html =~
               LocalizationHelpers.format_meeting_datetime(
                 seat.verification_deadline_at,
                 "Asia/Tokyo"
               )

      assert %{email_verified_at: nil, cancelled_at: nil} = reload(seat)
      assert reload(slot).status == :awaiting_verification
      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: EmailWorker)
    end

    test "a seat link confirms the seat", %{conn: conn, user: user} do
      {slot, seat} = held_seat(user, in_minutes(30))
      {:ok, view, _html} = live(conn, seat_path(seat))

      assert confirm(view) =~ "Your booking is confirmed"
      assert %{email_verified_at: %DateTime{}, cancelled_at: nil} = reload(seat)
      assert reload(slot).status == :confirmed

      {:ok, reloaded, _html} = live(conn, seat_path(seat))
      assert render(reloaded) =~ "This booking is already confirmed"
    end

    test "a seat link after expiry reads expired", %{conn: conn, user: user} do
      # The slot's marker is still in the future; the seat's hold is not.
      {slot, seat} = held_seat(user, in_minutes(-1))

      {:ok, view, _html} = live(conn, seat_path(seat))

      html = render(view)
      assert html =~ "This booking is no longer held"
      assert html =~ "This booking is no longer available, so your place was released."
      assert has_element?(view, "[data-testid='rebook-link'][href='/verify-host/workshop']")
      refute has_element?(view, "[data-testid='confirm-booking']")
      assert %{email_verified_at: nil, cancelled_at: nil} = reload(seat)
      assert reload(slot).status == :awaiting_verification
    end

    test "a seat link on a slot awaiting a new time stays held, not expired", %{
      conn: conn,
      user: user
    } do
      {slot, seat} =
        held_seat(user, in_minutes(30),
          status: :confirmed,
          verification_deadline_at: nil,
          reschedule_requested_at: DateTime.utc_now(:second)
        )

      {:ok, view, _html} = live(conn, seat_path(seat))

      refute render(view) =~ "This booking is no longer held"
      html = quietly(fn -> confirm(view) end)

      # A retry is refused while the request is pending, so the page does not
      # ask for one now.
      assert html =~ "The organiser is changing this meeting&#39;s time"
      assert html =~ "You can try again while your place is held."
      refute html =~ "We could not confirm your booking just now."
      refute html =~ "This booking is no longer held"
      assert has_element?(view, "[data-testid='confirm-booking']")
      assert %{email_verified_at: nil, cancelled_at: nil} = reload(seat)
      assert reload(slot).status == :confirmed
    end

    # As a one-to-one booking awaiting a new time reads as already confirmed.
    test "a confirmed seat's link reads confirmed while its slot awaits a new time", %{
      conn: conn,
      user: user
    } do
      {slot, seat} =
        held_seat(user, in_minutes(30), status: :confirmed, verification_deadline_at: nil)

      {:ok, view, _html} = live(conn, seat_path(seat))

      # Confirmed in another tab, then the host asked for a new time, before
      # this tab's click.
      {:ok, :verified, _slot} = EmailVerification.verify_seat(seat)

      slot
      |> reload()
      |> Changeset.change(reschedule_requested_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert confirm(view) =~ "This booking is already confirmed"

      {:ok, reloaded, _html} = live(conn, seat_path(seat))
      html = render(reloaded)
      assert html =~ "This booking is already confirmed"
      refute html =~ "This link is not valid"
    end

    test "a seat link confirmed after its deadline releases the seat", %{
      conn: conn,
      user: user
    } do
      {slot, seat} = held_seat(user, in_minutes(10))
      {:ok, view, _html} = live(conn, seat_path(seat))

      freeze_clock(DateTime.add(seat.verification_deadline_at, 1, :minute))

      assert confirm(view) =~ "This booking is no longer held"
      assert %{email_verified_at: nil, cancelled_at: %DateTime{}} = reload(seat)
      assert reload(slot).status == :expired
    end

    test "a seat link's 'this wasn't me' releases the seat silently", %{
      conn: conn,
      user: user
    } do
      insert(:webhook, user: user, events: ["meeting.created", "meeting.cancelled"])
      {slot, seat} = held_seat(user, in_minutes(30))
      {:ok, view, _html} = live(conn, seat_path(seat))

      html = view |> element("[data-testid='release-booking']") |> render_click()

      assert html =~ "The booking was cancelled and your place released."
      assert %{email_verified_at: nil, cancelled_at: %DateTime{}} = reload(seat)
      # It was the slot's only held seat, so the held slot goes with it.
      assert reload(slot).status == :expired
      refute_enqueued(worker: EmailWorker)
      refute_enqueued(worker: WebhookWorker)
      refute_enqueued(worker: CalendarEventWorker)
    end

    # Other attendees still hold the slot's time, so the page must not tell
    # the lapsed booker the time was released.
    test "a lapsed seat on a slot others still hold says only its place was released", %{
      conn: conn,
      user: user
    } do
      {slot, seat} =
        held_seat(user, in_minutes(-1), status: :confirmed, verification_deadline_at: nil)

      insert(:participant, meeting: slot, email: "confirmed@example.com")

      {:ok, view, _html} = live(conn, seat_path(seat))

      html = render(view)
      assert html =~ "This booking is no longer held"
      assert html =~ "This booking is no longer available, so your place was released."
      refute html =~ "the time was released"
      refute html =~ "This booking has expired"
      assert reload(slot).status == :confirmed
    end

    # A disowned seat writes the same row as a lapsed one, so its reload
    # reads in words true of both rather than as an expiry.
    test "reloading a disowned seat's link reads neutrally", %{conn: conn, user: user} do
      {slot, seat} = held_seat(user, in_minutes(30))

      insert(:participant,
        meeting: slot,
        email: "other-held@example.com",
        verification_deadline_at: in_minutes(30)
      )

      {:ok, view, _html} = live(conn, seat_path(seat))
      view |> element("[data-testid='release-booking']") |> render_click()

      {:ok, reloaded, _html} = live(conn, seat_path(seat))

      html = render(reloaded)
      assert html =~ "This booking is no longer held"
      assert html =~ "This booking is no longer available, so your place was released."
      refute html =~ "This booking has expired"
      refute html =~ "the time was released"
      assert reload(slot).status == :awaiting_verification
    end
  end

  test "the token path is not logged" do
    assert Endpoint.request_log_level(%Plug.Conn{path_info: ["verify-booking", "x"]}) == false
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  # Every insert of the confirmation email job reports a failure, so the
  # verification rolls back; other jobs insert.
  defp refusing_confirmation(fun) do
    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn changeset ->
      if Changeset.get_field(changeset, :args)["action"] == "send_confirmation_emails",
        do: {:error, :queue_not_available},
        else: :meck.passthrough([changeset])
    end)

    try do
      fun.()
    after
      :meck.unload(Oban)
    end
  end
end
