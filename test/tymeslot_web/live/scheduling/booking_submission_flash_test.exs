defmodule TymeslotWeb.Live.Scheduling.BookingSubmissionFlashTest do
  @moduledoc """
  Regression tests for what `BookingSubmissionHandlerComponent`'s failure
  branches leave behind on the socket. Two things must hold on every branch:
  the booker is told what went wrong, and they can act on it.

  **The flash reaches the parent** (Task 95). The booking form is rendered
  inside a `Phoenix.LiveComponent` and the handler decorates its socket with
  flashes on every failure branch. Those flashes used to be silently dropped
  because `put_flash/3` on a component socket never reaches the root
  LiveView. We now forward them through
  `TymeslotWeb.Live.Shared.Flash.put_flash/3`, which the scheduling LiveView
  picks up in `handle_info({:flash, _}, _)`.

  **The submission lock is released.** `check_duplicate_submission/1` claims
  `:submission_processed` before the rate-limit and reCAPTCHA gates run, so a
  branch that clears only `:submitting` leaves the lock set. The booker's next
  submit in that session is then answered with "already being processed" and
  the form stays wedged until they reload the page — a rejected attempt
  becomes an unbookable session. Observed in production: a booker hit a low
  reCAPTCHA score, retried, and got "already being processed" instead.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # Disable reCAPTCHA by default so tests targeting the other gates stay
    # hermetic regardless of env configuration. The two reCAPTCHA tests
    # re-enable it via `enable_recaptcha/0`, so restore the keys too.
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    old_site_key = System.get_env("RECAPTCHA_SITE_KEY")
    old_secret_key = System.get_env("RECAPTCHA_SECRET_KEY")
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, old_cfg)
      restore_env("RECAPTCHA_SITE_KEY", old_site_key)
      restore_env("RECAPTCHA_SECRET_KEY", old_secret_key)
    end)

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "testuser",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    insert(:calendar_integration, user: user, provider: "google", is_active: true)

    event_type = insert(:meeting_type, user: user, duration_minutes: 30, is_active: true)

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    %{profile: profile, event_type: event_type}
  end

  test "forwards rate-limit error flash from booking component to parent LiveView", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    view = navigate_to_booking_form(conn, profile, event_type)

    # The scheduling LiveView captures the client IP during mount from
    # the test conn's peer data. Saturate the booking-submission
    # rate-limit bucket for that key so the next submit hits
    # `BookingSubmissionHandlerComponent.check_rate_limit/1`'s `{:deny, _}`
    # branch — the branch that used to silently drop its "Too many
    # booking attempts." flash.
    client_ip = client_ip_for(view)
    saturate_booking_rate_limit(client_ip)

    params = %{
      "name" => "Rate Limited",
      "email" => "rate@example.com",
      "message" => "",
      "website" => ""
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # The flash is delivered to the parent via `send(self(), {:flash, _})`
    # from the submission handler. That message is processed asynchronously
    # relative to the `phx-submit` reply, so drain the LiveView's mailbox
    # via a synchronous `:sys.get_state/1` before asserting on the render.
    _drain = :sys.get_state(view.pid)

    assert render(view) =~ "Too many booking attempts"
  end

  test "blocks a booking when the attendee mailbox is rate-limited from another IP", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    view = navigate_to_booking_form(conn, profile, event_type)

    # Do NOT saturate the per-IP bucket — clear_all/0 in setup leaves it empty,
    # so the only limit that can trip here is the per-recipient one. This proves
    # the recipient check stops mailbox bombing even when each request comes from
    # a fresh source IP (the per-IP bucket alone would not catch that).
    victim_email = "victim-flash@example.com"
    saturate_booking_recipient(victim_email)

    params = %{
      "name" => "Mailbox Bomb",
      "email" => victim_email,
      "message" => "",
      "website" => ""
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    assert render(view) =~ "Too many booking attempts"
  end

  describe "retrying in the same session after a gate rejected the submission" do
    test "after the per-IP rate limit blocked it", %{
      conn: conn,
      profile: profile,
      event_type: event_type
    } do
      view = navigate_to_booking_form(conn, profile, event_type)
      saturate_booking_rate_limit(client_ip_for(view))

      assert submit_booking(view, "retry-ip@example.com") =~ "Too many booking attempts"

      # The window passes and the booker tries again.
      RateLimiter.clear_all()

      assert_retry_succeeds(view, "retry-ip@example.com")
    end

    test "after the per-recipient rate limit blocked it", %{
      conn: conn,
      profile: profile,
      event_type: event_type
    } do
      view = navigate_to_booking_form(conn, profile, event_type)
      saturate_booking_recipient("retry-mailbox@example.com")

      assert submit_booking(view, "retry-mailbox@example.com") =~ "Too many booking attempts"

      RateLimiter.clear_all()

      assert_retry_succeeds(view, "retry-mailbox@example.com")
    end

    test "after a failed reCAPTCHA check", %{
      conn: conn,
      profile: profile,
      event_type: event_type
    } do
      enable_recaptcha()
      view = navigate_to_booking_form(conn, profile, event_type)

      # The form carries no token, so the score check rejects this attempt.
      assert submit_booking(view, "retry-captcha@example.com") =~
               "Security verification failed"

      # The booker retries and this time clears the gate. Standing in for a
      # passing score, which needs a live Google verification round-trip.
      Application.put_env(:tymeslot, :recaptcha, booking_enabled: false)

      assert_retry_succeeds(view, "retry-captcha@example.com")
    end

    test "after the reCAPTCHA script was blocked", %{
      conn: conn,
      profile: profile,
      event_type: event_type
    } do
      enable_recaptcha()
      view = navigate_to_booking_form(conn, profile, event_type)

      # The client-side hook reports that the script never loaded, the branch a
      # privacy extension or restrictive CSP produces.
      send(
        view.pid,
        {:step_event, :booking, :submit,
         %{
           "name" => "Script Blocked",
           "email" => "retry-blocked@example.com",
           "message" => "",
           "website" => "",
           "g-recaptcha-response" => "RECAPTCHA_SCRIPT_BLOCKED"
         }}
      )

      _drain = :sys.get_state(view.pid)
      assert render(view) =~ "Security verification is currently unavailable"

      Application.put_env(:tymeslot, :recaptcha, booking_enabled: false)

      assert_retry_succeeds(view, "retry-blocked@example.com")
    end
  end

  # Submits the booking form and returns the parent view's markup once the
  # handler's async `{:flash, _}` message has been processed.
  defp submit_booking(view, email) do
    params = %{
      "name" => "Retry Booker",
      "email" => email,
      "message" => "",
      "website" => ""
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    _drain = :sys.get_state(view.pid)
    render(view)
  end

  # The point of these tests: a second submit after a rejected one must be
  # processed on its merits, not swallowed by the duplicate-submission guard.
  defp assert_retry_succeeds(view, email) do
    refute submit_booking(view, email) =~ "already being processed"

    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)
    assert Repo.aggregate(MeetingSchema, :count, :id) == 1
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp enable_recaptcha do
    Application.put_env(:tymeslot, :recaptcha,
      booking_enabled: true,
      booking_min_score: 0.3,
      booking_action: "booking_form",
      expected_hostnames: []
    )

    System.put_env("RECAPTCHA_SITE_KEY", "test_site_key")
    System.put_env("RECAPTCHA_SECRET_KEY", "test_secret_key")
  end

  defp saturate_booking_recipient(email) do
    # `check_booking_recipient_limit/1` allows 5 bookings per hour per mailbox.
    Enum.each(1..5, fn _i ->
      RateLimiter.check_booking_recipient_limit(email)
    end)
  end

  defp saturate_booking_rate_limit(client_ip) do
    # `check_booking_submission_limit/1` allows 10 requests per 20 minutes.
    # Burn through the budget so the next call from the LiveView returns
    # `{:deny, _}`.
    Enum.each(1..10, fn _i ->
      RateLimiter.check_booking_submission_limit(client_ip)
    end)
  end

  # Reads the `client_ip` assigned on the root scheduling LiveView. The
  # LiveView captures it during mount from the test conn's peer data, so
  # mirroring that value is the only way to saturate the correct bucket.
  defp client_ip_for(view) do
    state = :sys.get_state(view.pid)
    state.socket.assigns[:client_ip] || "unknown"
  end
end
