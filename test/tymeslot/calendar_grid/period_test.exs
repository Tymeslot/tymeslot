defmodule Tymeslot.CalendarGrid.PeriodTest do
  @moduledoc """
  The days each calendar view shows and how it steps. `assets/js/calendar/time.js`
  mirrors `days/4` and `shift/3` so the browser can draw the next period before
  the server answers; its tests pin the same cases.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.Period

  describe "parse_view/2" do
    test "reads the three views the surface draws" do
      assert Period.parse_view("day", :week) == :day
      assert Period.parse_view("three_day", :week) == :three_day
      assert Period.parse_view("week", :day) == :week
    end

    test "falls back for anything else, including views not built yet" do
      assert Period.parse_view("month", :week) == :week
      assert Period.parse_view(nil, :day) == :day
      assert Period.parse_view(42, :week) == :week
    end
  end

  test "default_view/1 opens the stored day view and the week for everything else" do
    assert Period.default_view("day") == :day
    assert Period.default_view("week") == :week
    assert Period.default_view("month") == :week
    assert Period.default_view(nil) == :week
  end

  test "parse_date/2 reads ISO dates and falls back otherwise" do
    assert Period.parse_date("2026-10-16", ~D[2026-01-01]) == ~D[2026-10-16]
    assert Period.parse_date("16/10/2026", ~D[2026-01-01]) == ~D[2026-01-01]
    assert Period.parse_date(nil, ~D[2026-01-01]) == ~D[2026-01-01]
  end

  test "week_start/1 reads the stored preference" do
    assert Period.week_start("sunday") == :sunday
    assert Period.week_start("monday") == :monday
    assert Period.week_start(nil) == :monday
  end

  describe "days/4" do
    test "a Monday-start week around a Friday" do
      assert Period.days(:week, ~D[2026-10-16], :monday, true) ==
               Enum.map(12..18, &Date.new!(2026, 10, &1))
    end

    test "a Sunday-start week" do
      assert Period.days(:week, ~D[2026-10-16], :sunday, true) ==
               Enum.map(11..17, &Date.new!(2026, 10, &1))
    end

    test "Sunday belongs to the week before it when weeks start on Monday" do
      assert List.first(Period.days(:week, ~D[2026-10-18], :monday, true)) == ~D[2026-10-12]
    end

    test "hidden weekends leave the working days" do
      assert Period.days(:week, ~D[2026-10-16], :monday, false) ==
               Enum.map(12..16, &Date.new!(2026, 10, &1))
    end

    test "three days run forward from the anchor" do
      assert Period.days(:three_day, ~D[2026-10-30], :monday, true) ==
               [~D[2026-10-30], ~D[2026-10-31], ~D[2026-11-01]]
    end

    test "a day is itself" do
      assert Period.days(:day, ~D[2026-10-16], :monday, false) == [~D[2026-10-16]]
    end
  end

  test "shift/3 steps by the view's length" do
    assert Period.shift(:week, ~D[2026-10-16], 1) == ~D[2026-10-23]
    assert Period.shift(:three_day, ~D[2026-10-16], -1) == ~D[2026-10-13]
    assert Period.shift(:day, ~D[2026-10-31], 1) == ~D[2026-11-01]
  end

  describe "window/4" do
    test "covers the previous, current and next week" do
      window = Period.window(:week, ~D[2026-10-16], :monday, true)

      assert window.first == ~D[2026-10-05]
      assert window.last == ~D[2026-10-25]
    end

    test "stays contiguous when weekends are hidden" do
      window = Period.window(:week, ~D[2026-10-16], :monday, false)

      assert {window.first, window.last} == {~D[2026-10-05], ~D[2026-10-25]}
    end

    test "covers nine days around a three-day view" do
      window = Period.window(:three_day, ~D[2026-10-16], :monday, true)

      assert {window.first, window.last} == {~D[2026-10-13], ~D[2026-10-21]}
    end
  end

  test "month_matrix/2 is six weeks starting on the week start before the first" do
    weeks = Period.month_matrix(~D[2026-10-16], :monday)

    assert length(weeks) == 6
    assert Enum.all?(weeks, &(length(&1) == 7))
    assert hd(hd(weeks)) == ~D[2026-09-28]
    assert List.last(List.last(weeks)) == ~D[2026-11-08]
  end
end
