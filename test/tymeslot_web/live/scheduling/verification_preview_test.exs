defmodule TymeslotWeb.Live.Scheduling.VerificationPreviewTest do
  @moduledoc """
  The public booking page on a meeting type that requires the attendee to
  confirm their email address: the form says a link will follow, a booking
  ends on "Check your inbox" in every shipped theme without ever putting the
  booking's uid on the page, "Resend email" sends the link again through the
  LiveView (rate-limited per client and capped per booking), and an owner
  previewing the page books a simulation that skips verification.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :themes
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Ecto.Changeset
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Live.Scheduling.PreviewToken
  alias TymeslotWeb.ThemeTestMatrix

  @attendee %{name: "Ana Lima", email: "ana@example.com"}

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, recaptcha) end)

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}" do
      @tag :capture_log
      test "the booking form says confirmation by email will be needed", %{conn: conn} do
        gated = seed(unquote(theme.id), "verify-form-#{unquote(theme.slug)}", true)
        {:ok, view, _html} = live(conn, "/#{gated.profile.username}")
        BookingDriver.book(view, until: :attendee)

        assert has_element?(view, "[data-testid='verification-notice']")

        ungated = seed(unquote(theme.id), "plain-form-#{unquote(theme.slug)}", false)
        {:ok, plain, _html} = live(conn, "/#{ungated.profile.username}")
        BookingDriver.book(plain, until: :attendee)

        assert has_element?(plain, "[data-testid='booking-form']")
        refute has_element?(plain, "[data-testid='verification-notice']")
      end

      @tag :capture_log
      test "booking a gated type ends on check your inbox", %{conn: conn} do
        %{user: user, profile: profile} =
          seed(unquote(theme.id), "verify-book-#{unquote(theme.slug)}", true)

        {:ok, view, _html} = live(conn, "/#{profile.username}")
        html = BookingDriver.book(view, attendee: @attendee)

        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.status == :awaiting_verification

        assert view |> element("[data-testid='check-inbox']") |> render() =~ "ana@example.com"
        assert has_element?(view, "[data-testid='resend-verification']")
        refute has_element?(view, "[data-testid='add-to-calendar']")
        refute html =~ meeting.uid
      end
    end
  end

  @tag :capture_log
  test "owner preview skips verification", %{conn: conn} do
    %{user: user, profile: profile} = seed("1", "verify-preview", true)

    {:ok, view, _html} =
      live(conn, "/#{profile.username}?preview=true&preview_token=#{PreviewToken.sign(user.id)}")

    assert has_element?(view, "[data-testid='preview-notice']")
    BookingDriver.book(view, attendee: @attendee)

    assert view |> element("[data-testid='confirmation-heading']") |> render() =~
             "Meeting Confirmed!"

    refute has_element?(view, "[data-testid='check-inbox']")
    refute has_element?(view, "[data-testid='resend-verification']")
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  @tag :capture_log
  test "a forged resend on a page with no held booking does nothing", %{conn: conn} do
    %{profile: profile} = seed("1", "verify-forged", true)
    {:ok, view, _html} = live(conn, "/#{profile.username}")
    client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip]
    before = RateLimiter.remaining(:booking_verification_resend, client_ip)

    render_hook(view, "resend_verification_email", %{})

    assert Process.alive?(view.pid)
    refute has_element?(view, "[data-testid='resend-verification-status']")
    refute_enqueued(worker: EmailWorker)
    assert RateLimiter.remaining(:booking_verification_resend, client_ip) == before
  end

  describe "Resend email (Quill)" do
    setup %{conn: conn} do
      %{user: user, profile: profile} = seed("1", "verify-resend", true)
      {:ok, view, _html} = live(conn, "/#{profile.username}")
      BookingDriver.book(view, attendee: @attendee)

      %{view: view, user: user, meeting: Repo.get_by!(MeetingSchema, organizer_user_id: user.id)}
    end

    @tag :capture_log
    test "sends the link again, keeps the deadline and holds the button briefly",
         %{view: view, meeting: meeting} do
      html = resend(view)

      assert html =~ "Sent again"
      assert has_element?(view, "[data-testid='resend-verification'][disabled]")
      assert_enqueued(worker: EmailWorker, args: verification_send(meeting, 2))

      resent = reload(meeting)
      assert resent.verification_emails_sent == 2
      assert resent.verification_deadline_at == meeting.verification_deadline_at
      refute html =~ meeting.uid

      # A press while the button is held is refused by the server too.
      render_hook(view, "resend_verification_email", %{})
      assert reload(meeting).verification_emails_sent == 2

      {_timer, token, _then} = cooldown(view)
      send(view.pid, {:verification_resend_ready, token})
      refute has_element?(view, "[data-testid='resend-verification'][disabled]")

      resend(view)
      assert_enqueued(worker: EmailWorker, args: verification_send(meeting, 3))
    end

    @tag :capture_log
    test "an earlier booking's cooldown never ends a later booking's",
         %{view: view} do
      resend(view)
      {first_timer, first_token, _then} = cooldown(view)

      view |> element("[data-testid='schedule-another']") |> render_click()
      refute cooldown(view)
      refute Process.read_timer(first_timer)

      BookingDriver.book(view, attendee: @attendee)
      assert Repo.aggregate(MeetingSchema, :count, :id) == 2
      resend(view)

      send(view.pid, {:verification_resend_ready, first_token})
      assert has_element?(view, "[data-testid='resend-verification'][disabled]")
      assert render(view) =~ "Sent again"
      assert cooldown(view)
    end

    @tag :capture_log
    test "hides the button once the booking's resends are used up",
         %{view: view, meeting: meeting} do
      for _resend <- 1..3, do: {:ok, _counted} = EmailVerification.resend(meeting)

      assert resend(view) =~ "cannot send the email again"
      refute has_element?(view, "[data-testid='resend-verification']")
      assert reload(meeting).verification_emails_sent == 4
    end

    @tag :capture_log
    test "the last resend shows it was sent, then hides the button for good",
         %{view: view, meeting: meeting} do
      for send <- 2..4 do
        assert resend(view) =~ "Sent again"
        assert reload(meeting).verification_emails_sent == send

        {_timer, token, _then} = cooldown(view)
        send(view.pid, {:verification_resend_ready, token})
      end

      html = render(view)
      assert html =~ "cannot send the email again"
      refute html =~ "Sent again"
      refute has_element?(view, "[data-testid='resend-verification']")
    end

    @tag :capture_log
    test "after the deadline it says the time was released", %{view: view, meeting: meeting} do
      meeting
      |> Changeset.change(verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60))
      |> Repo.update!()

      assert resend(view) =~ "The time was released"
      refute has_element?(view, "[data-testid='resend-verification']")
      assert reload(meeting).status == :expired
    end

    @tag :capture_log
    test "a booking confirmed meanwhile has nothing to resend", %{view: view, meeting: meeting} do
      {:ok, :verified, _verified} = EmailVerification.verify(meeting)

      assert resend(view) =~ "no longer waiting for your confirmation"
      refute has_element?(view, "[data-testid='resend-verification']")
    end

    @tag :capture_log
    test "is rate limited per client", %{view: view, meeting: meeting} do
      client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip]
      assert is_binary(client_ip) and client_ip != "unknown"

      Enum.each(1..10, fn _i -> RateLimiter.check(:booking_verification_resend, client_ip) end)

      assert resend(view) =~ "Too many attempts"
      assert has_element?(view, "[data-testid='resend-verification']")
      assert reload(meeting).verification_emails_sent == nil
    end
  end

  defp seed(theme_id, username, gated) do
    seed_organiser(theme_id, username,
      types: [[name: "Quick Chat", duration_minutes: 30, requires_email_verification: gated]]
    )
  end

  defp resend(view) do
    view |> element("[data-testid='resend-verification']") |> render_click()
  end

  defp cooldown(view), do: :sys.get_state(view.pid).socket.assigns[:verification_resend_cooldown]

  defp verification_send(meeting, send) do
    %{"action" => "send_booking_email_verification", "meeting_id" => meeting.id, "send" => send}
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)
end
