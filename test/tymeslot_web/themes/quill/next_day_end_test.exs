defmodule TymeslotWeb.Themes.Quill.NextDayEndTest do
  @moduledoc """
  The booking step names the end of a meeting that runs past midnight, and says
  nothing for one that ends the day it starts.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live
  @moduletag :bookings

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  @note "[data-testid='booking-next-day-end']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  # One organiser whose only offer is the given hours and a meeting of
  # `duration` minutes, so the first slot of any day is the one the test books.
  defp host(hours, duration) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "quill-night",
        booking_theme: "1",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    for day_of_week <- 1..7 do
      insert(
        :weekly_availability,
        Keyword.merge([schedule: schedule, day_of_week: day_of_week, is_available: true], hours)
      )
    end

    insert(:calendar_integration, user: user, is_active: true)
    insert(:meeting_type, user: user, duration_minutes: duration, is_active: true)
    profile
  end

  # Skipped until Task 5 (the engine offering a window that ends the next day)
  # and Task 4 (the ends_next_day field) land; remove the tag then.
  @tag :skip
  @tag :capture_log
  test "names the end of a meeting that runs past midnight", %{conn: conn} do
    profile = host([start_time: ~T[23:00:00], end_time: ~T[01:00:00], ends_next_day: true], 120)

    view = BookingTestHelpers.navigate_to_booking_form(conn, profile, nil)

    assert has_element?(view, @note)
  end

  @tag :capture_log
  test "says nothing for a meeting that ends the day it starts", %{conn: conn} do
    profile = host([start_time: ~T[22:00:00], end_time: ~T[23:00:00]], 60)

    view = BookingTestHelpers.navigate_to_booking_form(conn, profile, nil)

    assert has_element?(view, "form[data-testid='booking-form']")
    refute has_element?(view, @note)
  end
end
