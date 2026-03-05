defmodule TymeslotWeb.BookingHoneypotTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  @moduledoc """
  Tests for honeypot-based bot detection in booking flow.

  Note: Honeypot detection happens *before* reCAPTCHA verification,
  so these tests validate that bot attempts are caught early without
  requiring Google API calls or valid reCAPTCHA tokens.
  """

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # Disable reCAPTCHA so these tests focus on honeypot detection only,
    # regardless of RECAPTCHA_BOOKING_ENABLED environment variable.
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    # Create a user with a profile and event type for booking
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

    %{user: user, profile: profile, event_type: event_type}
  end

  defp honeypot_booking_form(view, website_value) do
    params = %{
      "name" => "Honeypot Bot",
      "email" => "bot@example.com",
      "message" => "I am a bot",
      "website" => website_value
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()
  end

  test "honeypot submission with filled website field is dropped", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    view = navigate_to_booking_form(conn, profile, event_type)

    # Submit with honeypot filled
    honeypot_booking_form(view, "http://bot.example")

    # Should show fake success message
    assert render(view) =~ "Booking submitted successfully"

    # Should NOT create a meeting
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  test "honeypot submission with whitespace-only value is dropped", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    view = navigate_to_booking_form(conn, profile, event_type)

    honeypot_booking_form(view, "   ")

    assert render(view) =~ "Booking submitted successfully"
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  test "normal booking with empty honeypot field succeeds", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    view = navigate_to_booking_form(conn, profile, event_type)

    # Submit WITHOUT filling honeypot (normal user)
    params = %{
      "name" => "John Doe",
      "email" => "john@example.com",
      "message" => "Looking forward to meeting",
      "website" => ""
    }

    view
    |> form("form[data-testid='booking-form']", %{"booking" => params})
    |> render_submit()

    # Wait for the booking to be processed
    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    # Should create the meeting
    assert Repo.aggregate(MeetingSchema, :count, :id) == 1
  end

  test "honeypot triggers silently on bot submission", %{
    conn: conn,
    profile: profile,
    event_type: event_type
  } do
    view = navigate_to_booking_form(conn, profile, event_type)

    honeypot_booking_form(view, "http://spammer.com")

    # Should show fake success message to mislead bot
    assert render(view) =~ "Booking submitted successfully"

    # Should NOT create a meeting (silent drop)
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end
end
