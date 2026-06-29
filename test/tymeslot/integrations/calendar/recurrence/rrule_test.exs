defmodule Tymeslot.Integrations.Calendar.Recurrence.RRuleTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  describe "build/1 — frequency" do
    test "builds a daily rule" do
      assert RRule.build(%{freq: :daily}) == "FREQ=DAILY"
    end

    test "builds a weekly rule" do
      assert RRule.build(%{freq: :weekly}) == "FREQ=WEEKLY"
    end

    test "builds a monthly rule" do
      assert RRule.build(%{freq: :monthly}) == "FREQ=MONTHLY"
    end

    test "builds a yearly rule" do
      assert RRule.build(%{freq: :yearly}) == "FREQ=YEARLY"
    end
  end

  describe "build/1 — interval" do
    test "omits INTERVAL when 1" do
      assert RRule.build(%{freq: :daily, interval: 1}) == "FREQ=DAILY"
    end

    test "emits INTERVAL when greater than 1" do
      assert RRule.build(%{freq: :weekly, interval: 2}) == "FREQ=WEEKLY;INTERVAL=2"
    end

    test "treats nil interval as 1" do
      assert RRule.build(%{freq: :daily, interval: nil}) == "FREQ=DAILY"
    end
  end

  describe "build/1 — by_day" do
    test "emits BYDAY for a weekly rule with weekdays" do
      assert RRule.build(%{freq: :weekly, by_day: [:mo, :we, :fr]}) ==
               "FREQ=WEEKLY;BYDAY=MO,WE,FR"
    end

    test "omits BYDAY when empty" do
      assert RRule.build(%{freq: :weekly, by_day: []}) == "FREQ=WEEKLY"
    end

    test "preserves the order of supplied weekdays" do
      assert RRule.build(%{freq: :weekly, by_day: [:su, :sa]}) == "FREQ=WEEKLY;BYDAY=SU,SA"
    end
  end

  describe "build/1 — end conditions" do
    test "emits COUNT" do
      assert RRule.build(%{freq: :daily, count: 10}) == "FREQ=DAILY;COUNT=10"
    end

    test "emits UNTIL as a date with time and Z suffix" do
      assert RRule.build(%{freq: :weekly, until: ~D[2026-12-31]}) ==
               "FREQ=WEEKLY;UNTIL=20261231T235959Z"
    end

    test "COUNT takes precedence over UNTIL when both supplied" do
      result = RRule.build(%{freq: :daily, count: 5, until: ~D[2026-12-31]})
      assert result == "FREQ=DAILY;COUNT=5"
    end

    test "omits both when neither present (never-ending)" do
      assert RRule.build(%{freq: :daily}) == "FREQ=DAILY"
    end
  end

  describe "build/1 — combinations" do
    test "builds a full weekly rule with interval, by_day and count" do
      rule = %{freq: :weekly, interval: 2, by_day: [:mo, :we], count: 10}
      assert RRule.build(rule) == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10"
    end

    test "orders parts FREQ, INTERVAL, BYDAY, then end condition" do
      rule = %{freq: :weekly, interval: 3, by_day: [:tu], until: ~D[2027-01-01]}
      assert RRule.build(rule) == "FREQ=WEEKLY;INTERVAL=3;BYDAY=TU;UNTIL=20270101T235959Z"
    end
  end

  describe "parse/1" do
    test "parses frequency" do
      assert %{freq: :weekly} = RRule.parse("FREQ=WEEKLY")
    end

    test "parses interval" do
      assert %{freq: :daily, interval: 2} = RRule.parse("FREQ=DAILY;INTERVAL=2")
    end

    test "parses by_day into atoms" do
      assert %{freq: :weekly, by_day: [:mo, :we, :fr]} =
               RRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
    end

    test "parses count" do
      assert %{freq: :daily, count: 10} = RRule.parse("FREQ=DAILY;COUNT=10")
    end

    test "parses until from a date-time stamp" do
      assert %{freq: :weekly, until: ~D[2026-12-31]} =
               RRule.parse("FREQ=WEEKLY;UNTIL=20261231T235959Z")
    end

    test "parses until from a bare date stamp" do
      assert %{until: ~D[2026-12-31]} = RRule.parse("FREQ=WEEKLY;UNTIL=20261231")
    end

    test "is lenient about a leading RRULE: prefix" do
      assert %{freq: :weekly} = RRule.parse("RRULE:FREQ=WEEKLY")
    end

    test "ignores unknown tokens" do
      assert %{freq: :weekly} = RRule.parse("FREQ=WEEKLY;BYSETPOS=1;WKST=MO")
    end

    test "returns an empty map for a blank string" do
      assert RRule.parse("") == %{}
    end

    test "defaults a missing interval to absent rather than 1" do
      refute Map.has_key?(RRule.parse("FREQ=WEEKLY"), :interval)
    end
  end

  describe "build/2 — UNTIL value-type for all-day rules (issue #5)" do
    test "all-day rule emits UNTIL as bare YYYYMMDD (no time, no Z suffix)" do
      result = RRule.build(%{freq: :weekly, until: ~D[2026-12-31]}, all_day: true)
      assert String.contains?(result, "UNTIL=20261231")
      refute String.contains?(result, "T235959Z")
    end

    test "timed rule keeps UNTIL as UTC date-time (…T235959Z)" do
      result = RRule.build(%{freq: :weekly, until: ~D[2026-12-31]}, all_day: false)
      assert result == "FREQ=WEEKLY;UNTIL=20261231T235959Z"
    end

    test "timed rule (no all_day option) defaults to UTC date-time form" do
      result = RRule.build(%{freq: :daily, until: ~D[2026-06-30]})
      assert String.contains?(result, "UNTIL=20260630T235959Z")
    end

    test "COUNT is unaffected by all_day flag" do
      result = RRule.build(%{freq: :daily, count: 5}, all_day: true)
      assert result == "FREQ=DAILY;COUNT=5"
    end

    test "all-day UNTIL round-trips through parse/1 correctly" do
      rrule = RRule.build(%{freq: :weekly, until: ~D[2027-01-15]}, all_day: true)
      parsed = RRule.parse(rrule)
      assert parsed.until == ~D[2027-01-15]
    end
  end

  describe "round-trip build ∘ parse" do
    for rule <- [
          %{freq: :daily},
          %{freq: :weekly, interval: 2, by_day: [:mo, :we, :fr]},
          %{freq: :monthly, interval: 1, count: 6},
          %{freq: :yearly, until: ~D[2030-06-15]},
          %{freq: :weekly, by_day: [:sa, :su], count: 3}
        ] do
      test "round-trips #{inspect(rule)}" do
        rule = unquote(Macro.escape(rule))
        rebuilt = rule |> RRule.build() |> RRule.parse() |> RRule.build()
        assert rebuilt == RRule.build(rule)
      end
    end
  end
end
