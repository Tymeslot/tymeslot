defmodule Tymeslot.Availability.BusinessHoursTest do
  @moduledoc """
  Tests for the BusinessHours module.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.BusinessHours

  describe "business_day?" do
    test "returns true for weekdays (default)" do
      # Monday to Friday
      assert BusinessHours.business_day?(~D[2026-01-12], nil)
      assert BusinessHours.business_day?(~D[2026-01-13], nil)
      assert BusinessHours.business_day?(~D[2026-01-14], nil)
      assert BusinessHours.business_day?(~D[2026-01-15], nil)
      assert BusinessHours.business_day?(~D[2026-01-16], nil)
    end

    test "returns false for weekends (default)" do
      # Saturday and Sunday
      refute BusinessHours.business_day?(~D[2026-01-17], nil)
      refute BusinessHours.business_day?(~D[2026-01-18], nil)
    end
  end

  describe "windows_for_target_date/5" do
    # 2026-01-12 is a Monday (day_of_week 1).
    @monday ~D[2026-01-12]
    # 2026-01-17 is a Saturday (day_of_week 6).
    @saturday ~D[2026-01-17]

    test "same timezone: returns the expected window for a weekday (nil profile, fallback hours)" do
      # profile_id nil uses the fallback schedule (Mon–Fri, 11:00–19:30).
      # With the same owner and viewer timezone there is no midnight bleed, so
      # exactly one window is returned containing Monday itself.
      windows =
        BusinessHours.windows_for_target_date(@monday, nil, "Etc/UTC", "Etc/UTC", %{})

      assert length(windows) == 1

      [%{start_dt: start_dt, end_dt: end_dt, date: date}] = windows
      assert date == @monday
      assert DateTime.to_time(start_dt) == ~T[11:00:00]
      assert DateTime.to_time(end_dt) == ~T[19:30:00]
      assert start_dt.time_zone == "Etc/UTC"
    end

    test "owner east of viewer: previous-day window bleeds into target_date in viewer timezone" do
      # Owner is in America/New_York (UTC-5 in January), viewer in Asia/Tokyo (UTC+9).
      # The 14-hour gap means owner's Sunday evening hours fall on Monday in Tokyo.
      #
      # Sunday 22:00–23:00 New York → Monday 12:00–13:00 Tokyo (2026-01-12).
      # The function iterates target_date -1 (Sunday 2026-01-11); when those hours
      # are converted to Tokyo time the start_dt date equals the target_date, so
      # the window must be included.
      #
      # We inject the schedule via config to avoid database access, and pass a
      # non-nil profile_id so the schedule branch (not the nil fallback) is taken.
      # The overrides list is empty so no override can interfere.
      fake_profile_id = 1

      schedule = [
        # Sunday (day_of_week 7): owner works late — bleeds into Monday in Tokyo
        %{
          day_of_week: 7,
          is_available: true,
          start_time: ~T[22:00:00],
          end_time: ~T[23:00:00]
        },
        # Monday (day_of_week 1): regular hours, also visible in Tokyo
        %{
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        },
        # Tuesday (day_of_week 2): needed for the +1 day iteration
        %{
          day_of_week: 2,
          is_available: false
        }
      ]

      config = %{weekly_schedule: schedule, overrides: []}

      windows =
        BusinessHours.windows_for_target_date(
          @monday,
          fake_profile_id,
          "America/New_York",
          "Asia/Tokyo",
          config
        )

      # Two windows: the Sunday bleed (date = 2026-01-11) and the Monday window
      # (date = 2026-01-12). Both start_dt or end_dt fall on Monday in Tokyo.
      assert length(windows) == 2

      dates = Enum.map(windows, & &1.date)
      assert ~D[2026-01-11] in dates
      assert ~D[2026-01-12] in dates

      # The bleed window (from Sunday) must start on Monday in Tokyo
      bleed = Enum.find(windows, &(&1.date == ~D[2026-01-11]))
      assert DateTime.to_date(bleed.start_dt) == @monday
      assert bleed.start_dt.time_zone == "Asia/Tokyo"

      # The Monday window itself must also be present
      monday_window = Enum.find(windows, &(&1.date == @monday))
      assert DateTime.to_date(monday_window.start_dt) == @monday
    end

    test "weekend with no business hours returns an empty list (nil profile)" do
      # profile_id nil uses the fallback schedule which only covers Mon–Fri (1..5).
      # A Saturday has no hours, so all three adjacent-day lookups yield nil
      # datetimes and the function must return [].
      windows =
        BusinessHours.windows_for_target_date(@saturday, nil, "Etc/UTC", "Etc/UTC", %{})

      assert windows == []
    end
  end

  describe "breaks_for_day/3" do
    # 2026-01-12 is a Monday (day_of_week 1).
    @monday ~D[2026-01-12]

    test "returns [] when profile_id is nil" do
      # lookup_day_availability returns nil for a nil profile_id regardless of
      # the date or config, so breaks_for_day must return an empty list.
      assert BusinessHours.breaks_for_day(@monday, nil, %{}) == []
    end

    test "returns break tuples from the preloaded weekly schedule" do
      # Injects a schedule with two breaks for Monday to exercise the
      # %{breaks: breaks} branch and verify the {start_time, end_time} tuple shape.
      schedule = [
        %{
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00],
          breaks: [
            %{start_time: ~T[12:00:00], end_time: ~T[13:00:00]},
            %{start_time: ~T[15:00:00], end_time: ~T[15:15:00]}
          ]
        }
      ]

      result = BusinessHours.breaks_for_day(@monday, 1, %{weekly_schedule: schedule})

      assert result == [{~T[12:00:00], ~T[13:00:00]}, {~T[15:00:00], ~T[15:15:00]}]
    end

    test "returns [] when the schedule entry for the day has no breaks key" do
      # The day entry exists but contains no :breaks key; the pattern
      # %{breaks: breaks} does not match, so the _other branch returns [].
      schedule = [
        %{
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        }
      ]

      assert BusinessHours.breaks_for_day(@monday, 1, %{weekly_schedule: schedule}) == []
    end
  end
end
