defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers

  # The extremes of the timezone map: UTC+14 and UTC-12 are 26 hours apart, so
  # their local dates always differ, whatever moment the suite runs at. Each
  # zone's "today" is therefore a date the other zone must never highlight, and
  # the pair pins timezone awareness without depending on the time of day.
  @ahead_tz "Pacific/Kiritimati"
  @behind_tz "Etc/GMT+12"

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

    test "UTC+14 (Pacific/Kiritimati) today is highlighted there and not in UTC-12" do
      now = DateTime.utc_now()
      ahead_today = local_today(now, @ahead_tz)

      # Precondition: the two zones are never on the same calendar date, so the
      # date below is genuinely "not today" for the far-behind zone.
      assert Date.compare(ahead_today, local_today(now, @behind_tz)) != :eq

      assert PreferenceHelpers.day_header_class(ahead_today, @ahead_tz) =~ "turquoise"
      refute PreferenceHelpers.day_header_class(ahead_today, @behind_tz) =~ "turquoise"
    end

    test "UTC-12 (Etc/GMT+12) today is highlighted there and not in UTC+14" do
      now = DateTime.utc_now()
      behind_today = local_today(now, @behind_tz)

      assert Date.compare(behind_today, local_today(now, @ahead_tz)) != :eq

      assert PreferenceHelpers.day_header_class(behind_today, @behind_tz) =~ "turquoise"
      refute PreferenceHelpers.day_header_class(behind_today, @ahead_tz) =~ "turquoise"
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

  defp local_today(now, timezone) do
    now
    |> DateTime.shift_zone!(timezone)
    |> DateTime.to_date()
  end
end
