defmodule TymeslotWeb.Dashboard.CalendarGrid.HelpersTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers

  describe "all_day_events_for_day/2" do
    defp make_assigns(events) do
      %{visible_events: events, hidden_integration_ids: []}
    end

    defp all_day_event(start_date, end_date) do
      %{
        all_day: true,
        calendar_integration_id: 1,
        start_date: start_date,
        end_date: end_date,
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

  # visible_days/1 now reads from socket assigns (set by precompute_derived/1).
  # The computation logic lives in DataLoading — tested here via PreferenceHelpers.
  describe "visible_days computation via PreferenceHelpers" do
    test "week view with weekends hidden returns 5 days" do
      assigns = %{
        view: :week,
        date: ~D[2026-03-25],
        preferences: %{week_start_day: "monday", show_weekends: false}
      }

      ws = PreferenceHelpers.week_start(~D[2026-03-25], assigns)
      all_days = Enum.map(0..6, &Date.add(ws, &1))
      days = Enum.reject(all_days, fn d -> Date.day_of_week(d) in [6, 7] end)

      assert length(days) == 5
      assert Enum.all?(days, fn d -> Date.day_of_week(d) in 1..5 end)
    end

    test "week view with weekends shown returns 7 days" do
      assigns = %{
        view: :week,
        date: ~D[2026-03-25],
        preferences: %{week_start_day: "monday", show_weekends: true}
      }

      ws = PreferenceHelpers.week_start(~D[2026-03-25], assigns)
      days = Enum.map(0..6, &Date.add(ws, &1))
      assert length(days) == 7
    end

    test "month view with Sunday start begins on Sunday" do
      [first_day | _rest] = PreferenceHelpers.month_matrix(~D[2026-03-01], :sunday)

      assert first_day == ~D[2026-03-01]
      assert Date.day_of_week(first_day) == 7
    end

    test "month view with Monday start begins on Monday" do
      [first_day | _rest] = PreferenceHelpers.month_matrix(~D[2026-03-01], :monday)

      assert first_day == ~D[2026-02-23]
      assert Date.day_of_week(first_day) == 1
    end

    test "month view always returns 42 days" do
      assert length(PreferenceHelpers.month_matrix(~D[2026-03-01], :sunday)) == 42
    end
  end

  describe "col_count/1 with preferences" do
    test "week view returns 5 when weekends hidden" do
      assert Helpers.col_count(%{view: :week, preferences: %{show_weekends: false}}) == 5
    end

    test "week view returns 7 when weekends shown" do
      assert Helpers.col_count(%{view: :week, preferences: %{show_weekends: true}}) == 7
    end

    test "three_day view always returns 3" do
      assert Helpers.col_count(%{view: :three_day}) == 3
    end
  end

  describe "period_label/1" do
    test "three_day same month formats as start – end_day, year" do
      assigns = %{view: :three_day, date: ~D[2026-04-10]}
      assert PreferenceHelpers.period_label(assigns) == "April 10 – 12, 2026"
    end

    test "three_day crossing a month boundary includes both month names" do
      assigns = %{view: :three_day, date: ~D[2026-04-30]}
      assert PreferenceHelpers.period_label(assigns) == "April 30 – May 2, 2026"
    end

    test "week crossing a month boundary includes both month names" do
      # 2026-01-30 is a Friday; Monday start → week_start = 2026-01-26, week_end = 2026-02-01
      assigns = %{view: :week, date: ~D[2026-01-30], preferences: %{week_start_day: "monday"}}
      assert PreferenceHelpers.period_label(assigns) == "January 26 – February 1, 2026"
    end
  end

  describe "DataLoading.range_for_view/1 — three_day" do
    test "returns a one-day buffer before and after the three visible days" do
      assigns = %{view: :three_day, date: ~D[2026-03-10]}
      {start_dt, end_dt} = DataLoading.range_for_view(assigns)

      assert start_dt == DateTime.new!(~D[2026-03-09], ~T[00:00:00], "Etc/UTC")
      assert end_dt == DateTime.new!(~D[2026-03-13], ~T[00:00:00], "Etc/UTC")
    end
  end

  describe "DataLoading.visible_days/1 — three_day" do
    # visible_days/1 is private; precompute_derived/1 is the public entry point
    # that assigns its result onto the socket.
    test "three_day anchor date produces three consecutive days" do
      socket =
        DataLoading.precompute_derived(%Socket{
          assigns: %{
            __changed__: %{},
            view: :three_day,
            date: ~D[2026-03-10],
            events: [],
            hidden_integration_ids: []
          }
        })

      assert socket.assigns.visible_days == [~D[2026-03-10], ~D[2026-03-11], ~D[2026-03-12]]
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
end
