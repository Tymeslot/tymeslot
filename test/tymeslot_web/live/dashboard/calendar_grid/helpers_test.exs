defmodule TymeslotWeb.Dashboard.CalendarGrid.HelpersTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  describe "height_rem/2" do
    test "1-hour event returns 4.0rem" do
      start_dt = ~U[2026-03-12 10:00:00Z]
      end_dt = ~U[2026-03-12 11:00:00Z]
      assert Helpers.height_rem(start_dt, end_dt) == 4.0
    end

    test "very short event returns minimum floor of 0.5rem" do
      start_dt = ~U[2026-03-12 10:00:00Z]
      end_dt = ~U[2026-03-12 10:00:30Z]
      assert Helpers.height_rem(start_dt, end_dt) == 0.5
    end

    test "multi-hour event scales proportionally" do
      start_dt = ~U[2026-03-12 09:00:00Z]
      end_dt = ~U[2026-03-12 12:00:00Z]
      # 3h * 4rem/h = 12.0
      assert Helpers.height_rem(start_dt, end_dt) == 12.0
    end
  end

  describe "overlap_layout/1" do
    test "empty list returns empty" do
      assert Helpers.overlap_layout([]) == []
    end

    test "non-overlapping events get separate columns" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 11:00:00Z], end_at: ~U[2026-03-12 12:00:00Z]}

      result = Helpers.overlap_layout([e1, e2])
      # Both fit in column 0 since they don't overlap
      assert [{^e1, 0, 1}, {^e2, 0, 1}] = result
    end

    test "two overlapping events get different columns" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:30:00Z]}
      e2 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 11:00:00Z]}

      result = Helpers.overlap_layout([e1, e2])
      assert [{^e1, 0, 2}, {^e2, 1, 2}] = result
    end
  end

  describe "top_rem/2" do
    test "positions event using UTC hours when no timezone given" do
      dt = ~U[2026-03-12 06:00:00Z]
      # 6h * 60 / 60 * 4 = 24.0
      assert Helpers.top_rem(dt) == 24.0
    end

    test "converts to user timezone before computing position" do
      # 06:00 UTC = 09:00 in Etc/GMT-3 (UTC+3)
      dt = ~U[2026-03-12 06:00:00Z]
      # 9h * 60 / 60 * 4 = 36.0
      assert Helpers.top_rem(dt, "Etc/GMT-3") == 36.0
    end

    test "handles negative offset timezones correctly" do
      # 18:00 UTC = 13:00 in America/New_York (UTC-5 in March)
      dt = ~U[2026-03-12 18:00:00Z]
      # America/New_York is UTC-4 in March (DST) → 14:00 local
      # 14h * 60 / 60 * 4 = 56.0
      assert Helpers.top_rem(dt, "America/New_York") == 56.0
    end

    test "midnight UTC renders at top of grid" do
      dt = ~U[2026-03-12 00:00:00Z]
      assert Helpers.top_rem(dt) == 0.0
    end
  end

  describe "all_day_events_for_day/2" do
    defp make_assigns(events) do
      %{visible_events: events, hidden_integration_ids: []}
    end

    defp all_day_event(start_date, end_date) do
      %{
        all_day: true,
        calendar_integration_id: 1,
        start_at: DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
        end_at: DateTime.new!(end_date, ~T[00:00:00], "Etc/UTC")
      }
    end

    test "shows a single-day all-day event on its start date" do
      event = all_day_event(~D[2026-03-30], ~D[2026-03-31])
      assigns = make_assigns([event])

      assert [^event] = Helpers.all_day_events_for_day(assigns, ~D[2026-03-30])
    end

    test "does not show the event on the exclusive end date" do
      event = all_day_event(~D[2026-03-30], ~D[2026-03-31])
      assigns = make_assigns([event])

      assert [] = Helpers.all_day_events_for_day(assigns, ~D[2026-03-31])
    end

    test "does not show the event before its start date" do
      event = all_day_event(~D[2026-03-30], ~D[2026-03-31])
      assigns = make_assigns([event])

      assert [] = Helpers.all_day_events_for_day(assigns, ~D[2026-03-29])
    end

    test "shows a multi-day event on each day it spans" do
      event = all_day_event(~D[2026-03-29], ~D[2026-04-01])
      assigns = make_assigns([event])

      assert [^event] = Helpers.all_day_events_for_day(assigns, ~D[2026-03-29])
      assert [^event] = Helpers.all_day_events_for_day(assigns, ~D[2026-03-30])
      assert [^event] = Helpers.all_day_events_for_day(assigns, ~D[2026-03-31])
      assert [] = Helpers.all_day_events_for_day(assigns, ~D[2026-04-01])
    end

    test "excludes timed events" do
      timed = %{
        all_day: false,
        calendar_integration_id: 1,
        start_at: ~U[2026-03-30 00:00:00Z],
        end_at: ~U[2026-03-31 00:00:00Z]
      }

      assigns = make_assigns([timed])
      assert [] = Helpers.all_day_events_for_day(assigns, ~D[2026-03-30])
    end
  end

  describe "week_start/2" do
    test "defaults to Monday" do
      assigns = %{preferences: %{week_start_day: "monday"}}
      # 2026-03-25 is a Wednesday
      assert Helpers.week_start(~D[2026-03-25], assigns) == ~D[2026-03-23]
    end

    test "respects Sunday preference" do
      assigns = %{preferences: %{week_start_day: "sunday"}}
      # 2026-03-25 is a Wednesday; preceding Sunday is 2026-03-22
      assert Helpers.week_start(~D[2026-03-25], assigns) == ~D[2026-03-22]
    end

    test "handles nil preferences gracefully" do
      assigns = %{preferences: nil}
      assert Helpers.week_start(~D[2026-03-25], assigns) == ~D[2026-03-23]
    end
  end

  describe "visible_days/1 with preferences" do
    test "week view with weekends hidden returns 5 days" do
      assigns = %{
        view: :week,
        date: ~D[2026-03-25],
        preferences: %{week_start_day: "monday", show_weekends: false}
      }

      days = Helpers.visible_days(assigns)
      assert length(days) == 5
      assert Enum.all?(days, fn d -> Date.day_of_week(d) in 1..5 end)
    end

    test "week view with weekends shown returns 7 days" do
      assigns = %{
        view: :week,
        date: ~D[2026-03-25],
        preferences: %{week_start_day: "monday", show_weekends: true}
      }

      days = Helpers.visible_days(assigns)
      assert length(days) == 7
    end

    test "month view with Sunday start begins on Sunday" do
      assigns = %{
        view: :month,
        date: ~D[2026-03-15],
        preferences: %{week_start_day: "sunday"}
      }

      [first_day | _rest] = Helpers.visible_days(assigns)
      assert Date.day_of_week(first_day) == 7
    end

    test "month view with Monday start begins on Monday" do
      assigns = %{
        view: :month,
        date: ~D[2026-03-15],
        preferences: %{week_start_day: "monday"}
      }

      [first_day | _rest] = Helpers.visible_days(assigns)
      assert Date.day_of_week(first_day) == 1
    end

    test "month view always returns 42 days" do
      assigns = %{view: :month, date: ~D[2026-03-15], preferences: %{week_start_day: "sunday"}}
      assert length(Helpers.visible_days(assigns)) == 42
    end
  end

  describe "col_count/1 with preferences" do
    test "week view returns 5 when weekends hidden" do
      assert Helpers.col_count(%{view: :week, preferences: %{show_weekends: false}}) == 5
    end

    test "week view returns 7 when weekends shown" do
      assert Helpers.col_count(%{view: :week, preferences: %{show_weekends: true}}) == 7
    end
  end

  describe "format_hour/2" do
    test "12-hour format" do
      assigns = %{preferences: %{time_format: "12h"}}
      assert Helpers.format_hour(0, assigns) == "12 AM"
      assert Helpers.format_hour(13, assigns) == "01 PM"
    end

    test "24-hour format" do
      assigns = %{preferences: %{time_format: "24h"}}
      assert Helpers.format_hour(0, assigns) == "00:00"
      assert Helpers.format_hour(13, assigns) == "13:00"
      assert Helpers.format_hour(9, assigns) == "09:00"
    end
  end

  describe "format_time_range/2" do
    test "12-hour format" do
      event = %{
        all_day: false,
        start_at: ~U[2026-03-12 14:00:00Z],
        end_at: ~U[2026-03-12 15:30:00Z]
      }

      assert Helpers.format_time_range(event, "12h") =~ "PM"
    end

    test "24-hour format" do
      event = %{
        all_day: false,
        start_at: ~U[2026-03-12 14:00:00Z],
        end_at: ~U[2026-03-12 15:30:00Z]
      }

      assert Helpers.format_time_range(event, "24h") == "14:00 \u2013 15:30"
    end

    test "all-day event returns 'All day' regardless of format" do
      event = %{
        all_day: true,
        start_at: ~U[2026-03-12 00:00:00Z],
        end_at: ~U[2026-03-13 00:00:00Z]
      }

      assert Helpers.format_time_range(event, "24h") == "All day"
    end
  end

  describe "week_number/1" do
    test "returns ISO week number" do
      # 2026-01-01 is a Thursday, ISO week 1
      assert Helpers.week_number(~D[2026-01-01]) == 1
      # 2026-03-30 is a Monday, ISO week 14
      assert Helpers.week_number(~D[2026-03-30]) == 14
    end
  end

  describe "day_name_headers/1" do
    test "Monday start returns Mon first" do
      assigns = %{preferences: %{week_start_day: "monday"}}
      assert hd(Helpers.day_name_headers(assigns)) == "Mon"
    end

    test "Sunday start returns Sun first" do
      assigns = %{preferences: %{week_start_day: "sunday"}}
      assert hd(Helpers.day_name_headers(assigns)) == "Sun"
    end
  end

  describe "top_rem/2 - DST-aware timezone conversion" do
    test "10:00 UTC positions at 6:00 AM in America/New_York during EDT (UTC-4)" do
      # 2026-03-12 is during EDT (DST started 2026-03-08)
      # 10:00 UTC = 06:00 EDT (UTC-4)
      dt = ~U[2026-03-12 10:00:00Z]
      # 6h * 4rem/h = 24.0
      assert Helpers.top_rem(dt, "America/New_York") == 24.0
    end

    test "10:00 UTC positions at 5:00 AM in America/New_York during EST (UTC-5)" do
      # 2026-01-15 is during EST (standard time)
      # 10:00 UTC = 05:00 EST (UTC-5)
      dt = ~U[2026-01-15 10:00:00Z]
      # 5h * 4rem/h = 20.0
      assert Helpers.top_rem(dt, "America/New_York") == 20.0
    end

    test "event at 23:30 UTC in UTC+2 wraps to next day 01:30" do
      # 23:30 UTC = 01:30 next day in Etc/GMT-2 (UTC+2)
      dt = ~U[2026-03-12 23:30:00Z]
      # 1h30m = 90 minutes → 90/60 * 4 = 6.0
      assert Helpers.top_rem(dt, "Etc/GMT-2") == 6.0
    end
  end
end
