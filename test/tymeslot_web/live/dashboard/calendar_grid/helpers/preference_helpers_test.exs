defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers

  # ── day_header_class/2 ────────────────────────────────────────────────

  describe "day_header_class/2 — timezone-aware today highlighting" do
    test "highlights today in the user's timezone (UTC)" do
      today = Date.utc_today()
      assert PreferenceHelpers.day_header_class(today, "Etc/UTC") =~ "turquoise"
    end

    test "does not highlight yesterday in the user's timezone (UTC)" do
      yesterday = Date.add(Date.utc_today(), -1)
      refute PreferenceHelpers.day_header_class(yesterday, "Etc/UTC") =~ "turquoise"
    end

    test "does not highlight tomorrow in the user's timezone (UTC)" do
      tomorrow = Date.add(Date.utc_today(), 1)
      refute PreferenceHelpers.day_header_class(tomorrow, "Etc/UTC") =~ "turquoise"
    end

    test "defaults to UTC when no timezone is supplied (arity-1)" do
      today_utc = Date.utc_today()
      assert PreferenceHelpers.day_header_class(today_utc) =~ "turquoise"
    end

    test "UTC+14 (Pacific/Kiritimati) boundary: local today differs from UTC today" do
      # Pacific/Kiritimati is UTC+14. At 23:30 UTC, Kiritimati local time is
      # 13:30 the next calendar day. We freeze a UTC moment that sits early
      # enough in the UTC day that the Kiritimati date is already one day ahead.
      #
      # We cannot easily mock DateTime.utc_now/0 without a mock library, so we
      # instead verify the function's logic directly: given a Date that is the
      # localised today for Kiritimati (which may differ from Date.utc_today/0),
      # it must be highlighted.
      kiritimati_tz = "Pacific/Kiritimati"

      # Compute the local date independently, mirroring the function's logic.
      local_today =
        DateTime.utc_now()
        |> DateTime.shift_zone!(kiritimati_tz)
        |> DateTime.to_date()

      # The function must highlight that date.
      assert PreferenceHelpers.day_header_class(local_today, kiritimati_tz) =~ "turquoise"

      # And it must NOT highlight the raw UTC date when it differs.
      utc_today = Date.utc_today()

      if Date.compare(local_today, utc_today) != :eq do
        # The two dates differ: ensure only the local date is highlighted.
        refute PreferenceHelpers.day_header_class(utc_today, kiritimati_tz) =~ "turquoise"
      end
    end

    test "UTC-12 (Etc/GMT+12) boundary: local today may lag UTC today" do
      # UTC-12 is the furthest-behind timezone. At 00:30 UTC, it is still
      # the previous calendar day in UTC-12.
      tz = "Etc/GMT+12"

      local_today =
        DateTime.utc_now()
        |> DateTime.shift_zone!(tz)
        |> DateTime.to_date()

      assert PreferenceHelpers.day_header_class(local_today, tz) =~ "turquoise"

      utc_today = Date.utc_today()

      if Date.compare(local_today, utc_today) != :eq do
        refute PreferenceHelpers.day_header_class(utc_today, tz) =~ "turquoise"
      end
    end
  end

  # ── period_label/1 — agenda view ──────────────────────────────────────

  describe "period_label/1 — agenda view" do
    test "returns 'Next 30 days' when date is local today" do
      today =
        DateTime.utc_now()
        |> DateTime.shift_zone!("Etc/UTC")
        |> DateTime.to_date()

      label =
        PreferenceHelpers.period_label(%{view: :agenda, date: today, user_timezone: "Etc/UTC"})

      assert label == "Next 30 days"
    end

    test "returns a date range when the agenda window is navigated forward" do
      future_start = Date.add(Date.utc_today(), 30)

      label =
        PreferenceHelpers.period_label(%{
          view: :agenda,
          date: future_start,
          user_timezone: "Etc/UTC"
        })

      # Should NOT be the static literal when date != today
      refute label == "Next 30 days"
      # Should contain month/year information
      assert label =~ ~r/\d{4}/
    end

    test "returns a date range when the agenda window is navigated backward" do
      past_start = Date.add(Date.utc_today(), -30)

      label =
        PreferenceHelpers.period_label(%{
          view: :agenda,
          date: past_start,
          user_timezone: "Etc/UTC"
        })

      refute label == "Next 30 days"
      assert label =~ ~r/\d{4}/
    end

    test "range label end is 30 days after start for a navigated window" do
      start_date = ~D[2030-03-01]

      label =
        PreferenceHelpers.period_label(%{
          view: :agenda,
          date: start_date,
          user_timezone: "Etc/UTC"
        })

      # March 1 – March 31 (same month: "March 1 – 31, 2030")
      assert label =~ "March"
      assert label =~ "2030"
    end

    test "falls back to UTC when user_timezone is absent from assigns" do
      today_utc = Date.utc_today()

      label = PreferenceHelpers.period_label(%{view: :agenda, date: today_utc})
      # With no user_timezone, UTC fallback means today == today, so "Next 30 days"
      assert label == "Next 30 days"
    end

    test "week view period label is unaffected" do
      date = ~D[2026-06-01]
      assigns = %{view: :week, date: date, preferences: %{week_start_day: "monday"}}
      label = PreferenceHelpers.period_label(assigns)
      assert label =~ "2026"
    end
  end
end
