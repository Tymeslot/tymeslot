defmodule Tymeslot.Integrations.Calendar.Recurrence.PatternTest do
  @moduledoc """
  The repeat patterns the grid's editor builds: the choices a start date
  allows, the rule each pattern writes, and how stored rules read back, by
  meaning rather than spelling.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern

  # Tuesday 13 October 2026, 09:00 in Berlin.
  @start DateTime.new!(~D[2026-10-13], ~T[09:00:00], "Europe/Berlin")

  describe "choices/1" do
    test "the second Tuesday of a month is that, and its day" do
      assert Pattern.choices(~D[2026-10-13]) == [:day, {2, :tu}]
    end

    test "the fourth Tuesday that is also the month's last is both" do
      assert Pattern.choices(~D[2026-10-27]) == [:day, {4, :tu}, {-1, :tu}]
    end

    test "a fifth Friday is only the last, and the month's last weekday" do
      assert Pattern.choices(~D[2026-10-30]) == [:day, {-1, :fr}, {-1, :weekday}]
    end

    test "the month's last day is its last day and last weekend day" do
      assert Pattern.choices(~D[2026-10-31]) ==
               [:day, {-1, :sa}, {-1, :day}, {-1, :weekend_day}]
    end

    test "the first of a month is its first weekday too" do
      assert Pattern.choices(~D[2026-10-01]) == [:day, {1, :th}, {1, :weekday}]
    end
  end

  describe "build/3" do
    for {pattern, rule} <- [
          {%{freq: :daily, interval: 2}, "FREQ=DAILY;INTERVAL=2"},
          {%{freq: :weekly, by_day: [:tu, :th]}, "FREQ=WEEKLY;BYDAY=TU,TH"},
          {%{freq: :monthly, on: :day}, "FREQ=MONTHLY"},
          {%{freq: :monthly, on: {2, :tu}, count: 6}, "FREQ=MONTHLY;BYDAY=2TU;COUNT=6"},
          {%{freq: :monthly, on: {-1, :weekday}},
           "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"},
          {%{freq: :yearly, on: :day}, "FREQ=YEARLY"},
          {%{freq: :yearly, interval: 2, on: {2, :tu}},
           "FREQ=YEARLY;INTERVAL=2;BYMONTH=10;BYDAY=2TU"}
        ] do
      test "writes #{inspect(pattern)} as #{rule}" do
        assert Pattern.build(unquote(Macro.escape(pattern)), ~D[2026-10-13]) == unquote(rule)
      end
    end

    test "keeps the week start of the rule it replaces" do
      assert Pattern.build(%{freq: :weekly, interval: 2, by_day: [:tu, :su]}, ~D[2026-10-13],
               keep: "FREQ=WEEKLY;BYDAY=TU;WKST=SU"
             ) == "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=SU"
    end
  end

  describe "read/2" do
    for pattern <- [
          %{freq: :daily},
          %{freq: :weekly, by_day: [:tu, :th], interval: 2},
          %{freq: :monthly, on: :day, count: 10},
          %{freq: :monthly, on: {2, :tu}},
          %{freq: :yearly, on: {2, :tu}, interval: 3},
          %{freq: :yearly, on: :day, until: ~D[2030-10-13]}
        ] do
      test "reads back what it built for #{inspect(pattern)}" do
        pattern = unquote(Macro.escape(pattern))
        rule = Pattern.build(pattern, ~D[2026-10-13], timezone: "Europe/Berlin")

        assert {:ok, read} = Pattern.read(rule, @start)
        assert Pattern.build(read, ~D[2026-10-13], timezone: "Europe/Berlin") == rule
      end
    end

    test "reads no rule as no pattern" do
      assert Pattern.read(nil, @start) == {:ok, nil}
    end

    # Spellings other calendars write for patterns the editor builds.
    for {rule, pattern} <- [
          {"FREQ=MONTHLY;BYMONTHDAY=13", %{freq: :monthly, on: :day}},
          {"FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=13", %{freq: :yearly, on: :day}},
          {"FREQ=WEEKLY;BYDAY=TH,TU", %{freq: :weekly, by_day: [:tu, :th]}},
          {"FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR",
           %{freq: :weekly, by_day: [:mo, :tu, :we, :th, :fr]}},
          {"FREQ=WEEKLY", %{freq: :weekly, by_day: [:tu]}},
          {"RRULE:FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2", %{freq: :monthly, on: {2, :tu}}},
          {"FREQ=WEEKLY;BYDAY=TU;UNTIL=20261231",
           %{freq: :weekly, by_day: [:tu], until: ~D[2026-12-31]}}
        ] do
      test "reads #{rule} as the pattern it means" do
        assert Pattern.read(unquote(rule), @start) == {:ok, unquote(Macro.escape(pattern))}
      end
    end

    for rule <- [
          "FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1,-1",
          "FREQ=MONTHLY;BYMONTHDAY=1,15",
          "FREQ=MONTHLY;BYDAY=2TU,4TU",
          "FREQ=YEARLY;BYMONTH=1,7",
          "FREQ=YEARLY;BYWEEKNO=42",
          "FREQ=DAILY;INTERVAL=2;BYDAY=MO,TU",
          "FREQ=WEEKLY;BYDAY=WE",
          "FREQ=MONTHLY;BYDAY=3TU",
          "FREQ=MONTHLY;BYHOUR=9",
          "not a rule"
        ] do
      test "reads #{rule} as a custom rule" do
        assert Pattern.read(unquote(rule), @start) == :custom
      end
    end

    # 29 December 2026 is a fifth Tuesday: in months without one the two
    # rules differ.
    test "reads a fifth weekday as custom, not as the last" do
      start = DateTime.new!(~D[2026-12-29], ~T[09:00:00], "Europe/Berlin")
      assert Pattern.read("FREQ=MONTHLY;BYDAY=5TU", start) == :custom

      assert Pattern.read("FREQ=MONTHLY;BYDAY=-1TU", start) ==
               {:ok, %{freq: :monthly, on: {-1, :tu}}}
    end

    test "reads an all-day series from its date" do
      assert Pattern.read("FREQ=MONTHLY;BYDAY=2TU;UNTIL=20270112", ~D[2026-10-13]) ==
               {:ok, %{freq: :monthly, on: {2, :tu}, until: ~D[2027-01-12]}}
    end
  end

  describe "reanchor/2" do
    test "keeps a position the date is, and the start's day" do
      assert Pattern.reanchor({2, :tu}, ~D[2026-10-13]) == {2, :tu}
      assert Pattern.reanchor(:day, ~D[2026-10-14]) == :day
    end

    # 30 September 2026 is the last Wednesday of its month, 14 October the
    # second of its own.
    test "moves a position to the one of its kind the date is" do
      assert Pattern.reanchor({-1, :we}, ~D[2026-10-14]) == {2, :we}
      assert Pattern.reanchor({1, :weekday}, ~D[2026-10-14]) == :day
    end

    # 12 October 2026 is a second Monday, the 13th a second Tuesday, the
    # 27th the last Tuesday of the month and the 30th its last Friday.
    test "moves a weekday to the date's own, at the date's position" do
      assert Pattern.reanchor({2, :mo}, ~D[2026-10-13]) == {2, :tu}
      assert Pattern.reanchor({-1, :mo}, ~D[2026-10-27]) == {-1, :tu}
      assert Pattern.reanchor({1, :mo}, ~D[2026-10-30]) == {-1, :fr}
    end
  end

  describe "default_until/2" do
    test "is the day of the tenth occurrence, as ending after the default count" do
      assert Pattern.default_count() == 10
      assert Pattern.default_until(%{freq: :weekly}, ~D[2026-10-13]) == ~D[2026-12-15]
      assert Pattern.default_until(%{freq: :daily, interval: 3}, ~D[2026-10-13]) == ~D[2026-11-09]
    end

    test "follows a position, and ignores an end already set" do
      pattern = %{freq: :monthly, on: {2, :tu}, until: ~D[2026-11-01]}
      assert Pattern.default_until(pattern, ~D[2026-10-13]) == ~D[2027-07-13]
    end

    # 999 years apart, the tenth occurrence would fall past the last date a
    # calendar holds: the series ends on the last one it can.
    test "stops at the last date a calendar holds" do
      assert Pattern.default_until(%{freq: :yearly, interval: 999}, ~D[2026-10-13]) ==
               ~D[9019-10-13]
    end
  end

  describe "put_interval/2" do
    test "takes an interval above one, cut to the largest a pattern takes" do
      assert Pattern.put_interval(%{freq: :weekly}, 3) == %{freq: :weekly, interval: 3}
      assert Pattern.put_interval(%{freq: :weekly}, 5000) == %{freq: :weekly, interval: 999}
    end

    test "leaves a pattern repeating every period for one, less, or none" do
      for interval <- [1, 0, -2, nil] do
        assert Pattern.put_interval(%{freq: :weekly}, interval) == %{freq: :weekly}
      end
    end
  end

  describe "put_count/2" do
    test "takes a count above nought, cut to the largest a pattern takes" do
      assert Pattern.put_count(%{freq: :daily}, 6) == %{freq: :daily, count: 6}
      assert Pattern.put_count(%{freq: :daily}, 1000) == %{freq: :daily, count: 999}
    end

    test "starts a count not yet given from the default" do
      assert Pattern.put_count(%{freq: :daily}, nil) == %{freq: :daily, count: 10}
      assert Pattern.put_count(%{freq: :daily}, 0) == %{freq: :daily, count: 10}
    end
  end

  describe "put_until/3" do
    test "takes the date given" do
      assert Pattern.put_until(%{freq: :weekly}, ~D[2027-01-05], ~D[2026-10-13]) ==
               %{freq: :weekly, until: ~D[2027-01-05]}
    end

    test "without a date, ends on the default end from the start" do
      assert Pattern.put_until(%{freq: :weekly}, nil, ~D[2026-10-13]) ==
               %{freq: :weekly, until: ~D[2026-12-15]}
    end

    test "without a date or a start, leaves the pattern without an end" do
      assert Pattern.put_until(%{freq: :weekly}, nil, nil) == %{freq: :weekly}
    end
  end

  describe "equivalent?/3" do
    test "an UNTIL written as a date or as the instant ending that day is the same end" do
      assert Pattern.equivalent?(
               "FREQ=WEEKLY;BYDAY=TU;UNTIL=20261231",
               "FREQ=WEEKLY;BYDAY=TU;UNTIL=20261231T225959Z",
               @start
             )
    end

    test "rules making other occurrences differ" do
      refute Pattern.equivalent?("FREQ=MONTHLY;BYDAY=2TU", "FREQ=MONTHLY;BYDAY=-1TU", @start)
      refute Pattern.equivalent?("FREQ=WEEKLY", nil, @start)
      assert Pattern.equivalent?(nil, "", @start)
    end
  end
end
