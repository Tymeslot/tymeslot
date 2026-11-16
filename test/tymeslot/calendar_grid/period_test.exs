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

    test "reads month and agenda" do
      assert Period.parse_view("month", :week) == :month
      assert Period.parse_view("agenda", :day) == :agenda
    end

    test "falls back for anything else" do
      assert Period.parse_view("fortnight", :week) == :week
      assert Period.parse_view(nil, :day) == :day
      assert Period.parse_view(42, :week) == :week
    end
  end

  test "default_view/1 opens the stored view the surface draws, and the week for anything else" do
    assert Period.default_view("day") == :day
    assert Period.default_view("week") == :week
    assert Period.default_view("month") == :month
    assert Period.default_view("agenda") == :agenda
    assert Period.default_view("fortnight") == :week
    assert Period.default_view(nil) == :week
  end

  test "parse_date/2 reads ISO dates and falls back otherwise" do
    assert Period.parse_date("2026-10-16", ~D[2026-01-01]) == ~D[2026-10-16]
    assert Period.parse_date("16/10/2026", ~D[2026-01-01]) == ~D[2026-01-01]
    assert Period.parse_date(nil, ~D[2026-01-01]) == ~D[2026-01-01]
    assert Period.parse_date("9999-12-31", ~D[2026-01-01]) == ~D[2026-01-01]
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

  describe "views" do
    test "the desktop toolbar order and the phone's tab order" do
      assert Period.views() == [:day, :three_day, :week, :month, :agenda]
      assert Period.phone_views() == [:agenda, :day, :three_day, :month]
    end

    test "only day, three days and week are time grids" do
      assert Enum.filter(Period.views(), &Period.time_grid?/1) == [:day, :three_day, :week]
    end

    test "a week on a phone shows three days; every other view is itself" do
      assert Period.for_viewport(:week, :phone) == :three_day
      assert Period.for_viewport(:week, :wide) == :week
      assert Period.for_viewport(:month, :phone) == :month
      assert Period.for_viewport(:day, :phone) == :day
      assert Period.for_viewport(:agenda, :phone) == :agenda
    end
  end

  describe "month" do
    test "shows six weeks of seven days from the week start before the first" do
      days = Period.days(:month, ~D[2026-10-16], :monday, true)

      assert length(days) == 42
      assert {List.first(days), List.last(days)} == {~D[2026-09-28], ~D[2026-11-08]}
    end

    test "starts on Sunday when weeks do" do
      days = Period.days(:month, ~D[2026-10-16], :sunday, true)

      assert {List.first(days), List.last(days)} == {~D[2026-09-27], ~D[2026-11-07]}
    end

    test "keeps its weekends when the week hides them" do
      days = Period.days(:month, ~D[2026-10-16], :monday, false)

      assert length(days) == 42
      assert ~D[2026-10-17] in days
    end

    test "steps by a calendar month, keeping the day where the month has it" do
      assert Period.shift(:month, ~D[2026-10-16], 1) == ~D[2026-11-16]
      assert Period.shift(:month, ~D[2026-01-15], -1) == ~D[2025-12-15]
      assert Period.shift(:month, ~D[2026-12-15], 1) == ~D[2027-01-15]
    end

    test "31 January steps to the last day of February, leap years included" do
      assert Period.shift(:month, ~D[2026-01-31], 1) == ~D[2026-02-28]
      assert Period.shift(:month, ~D[2024-01-31], 1) == ~D[2024-02-29]
      assert Period.shift(:month, ~D[2026-03-31], -1) == ~D[2026-02-28]
    end

    test "loads from the previous month's grid to the next month's" do
      window = Period.window(:month, ~D[2026-10-16], :monday, true)

      assert {window.first, window.last} == {~D[2026-08-31], ~D[2026-12-06]}
      assert Date.diff(window.last, window.first) + 1 <= 112
    end

    test "a window around 31 January reaches the grids of December and February" do
      window = Period.window(:month, ~D[2026-01-31], :monday, true)

      assert {window.first, window.last} == {~D[2025-12-01], ~D[2026-03-08]}
    end
  end

  describe "agenda" do
    test "shows four weeks from its date" do
      days = Period.days(:agenda, ~D[2026-10-14], :monday, false)

      assert length(days) == Period.agenda_days()
      assert {List.first(days), List.last(days)} == {~D[2026-10-14], ~D[2026-11-10]}
    end

    test "steps by four weeks" do
      assert Period.shift(:agenda, ~D[2026-10-14], 1) == ~D[2026-11-11]
      assert Period.shift(:agenda, ~D[2026-10-14], -1) == ~D[2026-09-16]
    end

    test "loads four weeks before its date and eight from it" do
      window = Period.window(:agenda, ~D[2026-10-14], :monday, true)

      assert {window.first, window.last} == {~D[2026-09-16], ~D[2026-12-08]}
    end

    test "extends at most 24 weeks from its date" do
      assert Period.agenda_max_days() == 6 * Period.agenda_days()
    end
  end

  test "a day loads its week with a week either side, as the week view does" do
    assert Period.window(:day, ~D[2026-10-14], :monday, true) ==
             Period.window(:week, ~D[2026-10-14], :monday, true)

    window = Period.window(:day, ~D[2026-10-18], :sunday, true)
    assert {window.first, window.last} == {~D[2026-10-11], ~D[2026-10-31]}
  end

  describe "week_number/1" do
    defp row(first, count \\ 7), do: Enum.map(0..(count - 1), &Date.add(first, &1))

    test "numbers a Monday-start row by its Monday" do
      assert Period.week_number(row(~D[2026-10-12])) == 42
    end

    test "numbers a Sunday-start row by the Monday after its Sunday" do
      assert Period.week_number(row(~D[2026-10-11])) == 42
      assert Period.week_number(row(~D[2026-09-27])) == 40
      assert Period.week_number(row(~D[2027-01-03])) == 1
    end

    test "numbers a row without a Monday by its first day" do
      assert Period.week_number([~D[2026-10-18]]) == 42
      assert Period.week_number(row(~D[2027-01-01], 3)) == 53
    end

    test "week 53 and week 1 across the turn of the year" do
      assert Period.week_number([~D[2026-12-31]]) == 53
      assert Period.week_number([~D[2024-12-30]]) == 1
    end

    test "every row of a month matrix, either week start" do
      assert ~D[2026-10-14] |> Period.month_matrix(:monday) |> Enum.map(&Period.week_number/1) ==
               [40, 41, 42, 43, 44, 45]

      assert ~D[2026-10-14] |> Period.month_matrix(:sunday) |> Enum.map(&Period.week_number/1) ==
               [40, 41, 42, 43, 44, 45]
    end
  end

  describe "view_switch_anchor/4" do
    test "a week hands over today when today is in it" do
      assert Period.view_switch_anchor(:week, ~D[2026-10-16], ~D[2026-10-14], :monday) ==
               ~D[2026-10-14]
    end

    test "a week without today hands over its first day, mid-week anchor or not" do
      assert Period.view_switch_anchor(:week, ~D[2026-10-21], ~D[2026-10-14], :monday) ==
               ~D[2026-10-19]

      assert Period.view_switch_anchor(:week, ~D[2026-10-21], ~D[2026-10-14], :sunday) ==
               ~D[2026-10-18]
    end

    test "a week's first day follows the week start: Sunday 18th opens its own Sunday week" do
      assert Period.view_switch_anchor(:week, ~D[2026-10-18], ~D[2026-10-01], :sunday) ==
               ~D[2026-10-18]

      assert Period.view_switch_anchor(:week, ~D[2026-10-18], ~D[2026-10-01], :monday) ==
               ~D[2026-10-12]
    end

    test "a month hands over today when today is one of its own days" do
      assert Period.view_switch_anchor(:month, ~D[2026-10-20], ~D[2026-10-14], :monday) ==
               ~D[2026-10-14]
    end

    test "a month without today hands over its first, even when its grid shows today" do
      # The November grid starts on 26 October; today there is not November's.
      assert Period.view_switch_anchor(:month, ~D[2026-11-14], ~D[2026-10-28], :monday) ==
               ~D[2026-11-01]
    end

    test "the views that start at their date keep it" do
      for view <- [:day, :three_day, :agenda] do
        assert Period.view_switch_anchor(view, ~D[2026-10-21], ~D[2026-10-14], :monday) ==
                 ~D[2026-10-21]
      end
    end
  end
end
