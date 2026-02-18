defmodule TymeslotWeb.BookingRecaptchaTest do
  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  @moduletag backup_tests: true

  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Infrastructure.Security.Recaptcha
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    ensure_rate_limiter_started()
    RateLimiter.clear_all()

    TestMocks.setup_all_mocks()

    # Save original config and env vars
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    old_site_key = System.get_env("RECAPTCHA_SITE_KEY")
    old_secret_key = System.get_env("RECAPTCHA_SECRET_KEY")

    # Create test data
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "testuser",
        timezone: "America/New_York",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    # Calendar integration is required for booking flow
    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true
    )

    event_type = insert(:meeting_type, user: user, duration_minutes: 30, is_active: true)

    # Create weekly availability
    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, old_cfg)

      if old_site_key,
        do: System.put_env("RECAPTCHA_SITE_KEY", old_site_key),
        else: System.delete_env("RECAPTCHA_SITE_KEY")

      if old_secret_key,
        do: System.put_env("RECAPTCHA_SECRET_KEY", old_secret_key),
        else: System.delete_env("RECAPTCHA_SECRET_KEY")
    end)

    %{user: user, profile: profile, event_type: event_type}
  end

  # Helper to enable reCAPTCHA for tests
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

  test "booking is blocked when reCAPTCHA token is missing and reCAPTCHA is enabled", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    enable_recaptcha()
    view = navigate_to_booking_form(conn, profile, event_type)

    params = %{
      "name" => "Test User",
      "email" => "test@example.com",
      "message" => "Test message"
      # g-recaptcha-response field will be empty
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # Should stay on booking form with error
    assert render(view) =~ "Security verification failed"
    # Should not create booking
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  test "booking proceeds when reCAPTCHA is disabled", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    # Disable reCAPTCHA for this test
    Application.put_env(:tymeslot, :recaptcha, booking_enabled: false)

    view = navigate_to_booking_form(conn, profile, event_type)

    params = %{
      "name" => "Test User",
      "email" => "test@example.com",
      "message" => "Test message"
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # Wait for the booking to be processed
    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    # Should create the booking (reCAPTCHA disabled)
    assert Repo.aggregate(MeetingSchema, :count, :id) == 1
  end

  test "booking proceeds when reCAPTCHA is enabled but keys are missing", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    # Enable reCAPTCHA but don't set keys (should fail-open)
    Application.put_env(:tymeslot, :recaptcha,
      booking_enabled: true,
      booking_min_score: 0.3,
      booking_action: "booking_form",
      expected_hostnames: []
    )

    # Ensure keys are not set
    System.delete_env("RECAPTCHA_SITE_KEY")
    System.delete_env("RECAPTCHA_SECRET_KEY")

    view = navigate_to_booking_form(conn, profile, event_type)

    params = %{
      "name" => "Test User",
      "email" => "test@example.com",
      "message" => "Test message"
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # Wait for the booking to be processed
    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    # Should proceed (fail-open when keys missing)
    assert Repo.aggregate(MeetingSchema, :count, :id) == 1
  end

  test "booking with honeypot bypasses reCAPTCHA check", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    enable_recaptcha()
    view = navigate_to_booking_form(conn, profile, event_type)

    params = %{
      "name" => "Bot User",
      "email" => "bot@example.com",
      "message" => "Bot message",
      "website" => "http://bot.example"
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # Honeypot triggers before reCAPTCHA check
    assert render(view) =~ "Booking submitted successfully"
    # Honeypot: no booking created
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  test "booking fails when reCAPTCHA script is blocked (CSP, extension, or JS disabled)", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    enable_recaptcha()
    view = navigate_to_booking_form(conn, profile, event_type)

    # Simulate the client-side Recaptcha hook sending the special marker when the reCAPTCHA
    # script failed to load. We need to call the event handler directly.
    send(
      view.pid,
      {:step_event, :booking, :submit,
       %{
         "name" => "Test User",
         "email" => "test@example.com",
         "message" => "Test message",
         "g-recaptcha-response" => "RECAPTCHA_SCRIPT_BLOCKED"
       }}
    )

    # Wait for processing
    Process.sleep(100)

    # Should show helpful error message
    rendered = render(view)
    assert rendered =~ "Security verification is currently unavailable"
    assert rendered =~ "JavaScript being disabled"
    # No booking should be created
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  test "rate limiter is checked before reCAPTCHA verification (hybrid gate)", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    enable_recaptcha()

    params = %{
      "name" => "Test User",
      "email" => "rate-test@example.com",
      "message" => "Test message"
    }

    # Hit rate limit by making multiple booking attempts with fresh views
    # Each submission needs a fresh view to avoid duplicate submission check
    for _i <- 1..10 do
      view = navigate_to_booking_form(conn, profile, event_type)

      view
      |> form("form[data-testid='booking-form']", %{"booking" => params})
      |> render_submit()
    end

    # Next attempt should be rate-limited, NOT fail on reCAPTCHA
    view = navigate_to_booking_form(conn, profile, event_type)

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # Should show rate limit message
    rendered = render(view)
    assert rendered =~ "Too many" or rendered =~ "try again later"
  end

  describe "Edge cases - Token and data handling" do
    test "booking with very long token is rejected (DoS protection)" do
      enable_recaptcha()

      # Create a very large token (100KB+)
      huge_token = String.duplicate("X", 100_000)

      # Verify the token is rejected without crashing
      result = Recaptcha.verify(huge_token)
      assert result == {:error, :invalid_token}
    end

    test "token exceeding 5KB size limit is rejected early" do
      enable_recaptcha()

      # Create a token just over 5KB
      oversized_token = String.duplicate("X", 5_001)

      # Should be rejected before hitting Google API (prevents DoS)
      result = Recaptcha.verify(oversized_token)
      assert result == {:error, :invalid_token}
    end

    test "empty token is properly rejected with clear error" do
      enable_recaptcha()

      result =
        RecaptchaHelpers.maybe_verify_booking_token("", %{ip: "127.0.0.1", user_agent: "test"})

      assert result == {:error, :recaptcha_failed}
    end

    test "booking with nil token is rejected safely" do
      enable_recaptcha()

      result =
        RecaptchaHelpers.maybe_verify_booking_token(nil, %{ip: "127.0.0.1", user_agent: "test"})

      assert result == {:error, :recaptcha_failed}
    end
  end

  test "booking form includes reCAPTCHA elements when enabled", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    enable_recaptcha()

    view = navigate_to_booking_form(conn, profile, event_type)
    html = render(view)

    # Should include reCAPTCHA hook
    assert html =~ "phx-hook=\"RecaptchaV3\""
    # Should include hidden token field
    assert html =~ "booking[g-recaptcha-response]"
    # Should include privacy notice
    assert html =~ "protected by reCAPTCHA"
    assert html =~ "Google"
  end

  test "booking form does not include reCAPTCHA elements when disabled", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    # Ensure reCAPTCHA is disabled
    Application.put_env(:tymeslot, :recaptcha, booking_enabled: false)

    view = navigate_to_booking_form(conn, profile, event_type)
    html = render(view)

    # Should NOT include reCAPTCHA elements
    refute html =~ "phx-hook=\"RecaptchaV3\""
    refute html =~ "booking[g-recaptcha-response]"
    refute html =~ "protected by reCAPTCHA"
  end

  defp ensure_rate_limiter_started do
    case Process.whereis(Tymeslot.Security.RateLimiter) do
      nil -> start_supervised!(Tymeslot.Security.RateLimiter)
      _pid -> :ok
    end
  end
end
