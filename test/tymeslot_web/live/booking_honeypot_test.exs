defmodule TymeslotWeb.BookingHoneypotTest do
  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.MeetingSchema
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
    ensure_rate_limiter_started()
    RateLimiter.clear_all()

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

  # Helper to navigate to the booking form step
  defp navigate_to_booking_form(conn, profile, _event_type) do
    timezone = profile.timezone
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

    # Select the first meeting type
    view |> element("button[data-testid='duration-option']") |> render_click()

    # Navigate to date/time selection
    view |> element("button[data-testid='next-step']") |> render_click()

    # Wait for availability to load and select an available date
    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    date_str = Date.to_string(target_date)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()

    # Wait for time slots to load
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    # Extract and click the first available time slot
    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first() ||
        flunk("Expected at least one available time slot button after selecting a date")

    view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()

    # Navigate to the booking form
    view |> element("button[phx-click='next_step']") |> render_click()

    view
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

  defp ensure_rate_limiter_started do
    case Process.whereis(Tymeslot.Security.RateLimiter) do
      nil -> start_supervised!(Tymeslot.Security.RateLimiter)
      _pid -> :ok
    end
  end
end
