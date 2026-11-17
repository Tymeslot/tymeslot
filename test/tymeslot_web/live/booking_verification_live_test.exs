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
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  @moduletag :live
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Invitations
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.WebhookWorker
  alias TymeslotWeb.Endpoint

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

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

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
