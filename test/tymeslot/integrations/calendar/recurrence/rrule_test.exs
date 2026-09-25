defmodule Tymeslot.Integrations.Calendar.Recurrence.RRuleTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

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

  describe "retarget/2" do
    test "leaves a missing rule missing" do
      assert RRule.retarget(nil, all_day: true, start_date: ~D[2026-06-01]) == {:ok, nil}
    end

    test "rewrites a timed UNTIL as a bare date for an all-day event" do
      assert RRule.retarget("FREQ=WEEKLY;BYDAY=MO;UNTIL=20260630T235959Z",
               all_day: true,
               start_date: ~D[2026-06-01]
             ) == {:ok, "FREQ=WEEKLY;BYDAY=MO;UNTIL=20260630"}
    end

    test "rewrites a bare-date UNTIL as an end-of-day timestamp for a timed event" do
      assert RRule.retarget("FREQ=DAILY;UNTIL=20260630",
               all_day: false,
               start_date: ~D[2026-06-01]
             ) ==
               {:ok, "FREQ=DAILY;UNTIL=20260630T235959Z"}
    end

    test "keeps parts the editor does not understand" do
      assert RRule.retarget("RRULE:FREQ=MONTHLY;BYSETPOS=-1;UNTIL=20261231T235959Z",
               all_day: true,
               start_date: ~D[2026-06-01]
             ) == {:ok, "RRULE:FREQ=MONTHLY;BYSETPOS=-1;UNTIL=20261231"}
    end

    test "leaves a rule without UNTIL untouched" do
      assert RRule.retarget("FREQ=WEEKLY;COUNT=5", all_day: true, start_date: ~D[2026-06-01]) ==
               {:ok, "FREQ=WEEKLY;COUNT=5"}
    end

    test "accepts an UNTIL on the start date" do
      assert {:ok, "FREQ=DAILY;UNTIL=20260601"} =
               RRule.retarget("FREQ=DAILY;UNTIL=20260601T235959Z",
                 all_day: true,
                 start_date: ~D[2026-06-01]
               )
    end

    test "rejects an UNTIL before the start date" do
      assert RRule.retarget("FREQ=DAILY;UNTIL=20260531T235959Z",
               all_day: false,
               start_date: ~D[2026-06-01]
             ) == {:error, :until_before_start}
    end

    test "skips the start check when no start date is known" do
      assert RRule.retarget("FREQ=DAILY;UNTIL=20200101", all_day: false) ==
               {:ok, "FREQ=DAILY;UNTIL=20200101T235959Z"}
    end
  end

  describe "build/2 — a timed UNTIL ends its day in the event's timezone" do
    test "west of UTC the local day ends on the following UTC day" do
      assert RRule.build(%{freq: :daily, until: ~D[2026-06-30]},
               timezone: "America/Los_Angeles"
             ) == "FREQ=DAILY;UNTIL=20260701T065959Z"
    end

    test "east of UTC the local day ends earlier on the same UTC day" do
      assert RRule.build(%{freq: :daily, until: ~D[2026-06-30]}, timezone: "Pacific/Auckland") ==
               "FREQ=DAILY;UNTIL=20260630T115959Z"
    end

    test "an all-day UNTIL stays a bare date whatever timezone is supplied" do
      assert RRule.build(%{freq: :daily, until: ~D[2026-06-30]},
               all_day: true,
               timezone: "America/Los_Angeles"
             ) == "FREQ=DAILY;UNTIL=20260630"
    end

    test "an unrecognised timezone falls back to ending the day in UTC" do
      assert RRule.build(%{freq: :daily, until: ~D[2026-06-30]}, timezone: "Nowhere/Fictional") ==
               "FREQ=DAILY;UNTIL=20260630T235959Z"
    end
  end

  describe "build/2 — a timed UNTIL on a DST transition date" do
    # Egypt ends DST at 24:00 on the last Thursday of October, so 2026-10-29
    # runs 23:00–24:00 twice: once at EEST (+03) and again at EET (+02). The
    # day's last instant is the later of the pair, 23:59:59 +02 = 21:59:59Z.
    # Resolving the ambiguity the way a *start* instant is resolved, to the
    # first of the pair, ends the series an hour early and drops a 23:30
    # occurrence on the final day.
    test "an ambiguous local midnight ends the day at its later instant" do
      assert RRule.build(%{freq: :daily, until: ~D[2026-10-29]}, timezone: "Africa/Cairo") ==
               "FREQ=DAILY;UNTIL=20261029T215959Z"
    end

    # Chile springs forward at midnight, so 2026-09-06 00:00 never happens: the
    # clock goes straight from 2026-09-05 23:59:59 -04 to 01:00 -03. The last
    # instant of 5 September is therefore 23:59:59 -04 = 03:59:59Z on the 6th.
    test "a local midnight that never happens still ends the day before it" do
      assert RRule.build(%{freq: :daily, until: ~D[2026-09-05]}, timezone: "America/Santiago") ==
               "FREQ=DAILY;UNTIL=20260906T035959Z"
    end
  end

  describe "parse/2 — a timed UNTIL reads back as the organiser's local date" do
    test "west of UTC" do
      assert %{until: ~D[2026-06-30]} =
               RRule.parse("FREQ=DAILY;UNTIL=20260701T065959Z", timezone: "America/Los_Angeles")
    end

    test "east of UTC" do
      assert %{until: ~D[2026-06-30]} =
               RRule.parse("FREQ=DAILY;UNTIL=20260630T115959Z", timezone: "Pacific/Auckland")
    end

    test "a bare-date UNTIL is zone-free and reads as it is written" do
      assert %{until: ~D[2026-06-30]} =
               RRule.parse("FREQ=DAILY;UNTIL=20260630", timezone: "Pacific/Auckland")
    end

    test "without a timezone the UTC day is used, as before" do
      assert %{until: ~D[2026-07-01]} = RRule.parse("FREQ=DAILY;UNTIL=20260701T065959Z")
    end
  end

  describe "retarget/2 with a timezone" do
    test "rewrites a bare-date UNTIL as the end of that day where the organiser is" do
      assert RRule.retarget("FREQ=DAILY;UNTIL=20260630",
               all_day: false,
               timezone: "America/Los_Angeles"
             ) == {:ok, "FREQ=DAILY;UNTIL=20260701T065959Z"}
    end

    test "is idempotent: a rule already fitted to the zone is left alone" do
      opts = [all_day: false, timezone: "America/Los_Angeles"]

      assert {:ok, fitted} = RRule.retarget("FREQ=DAILY;UNTIL=20260630", opts)
      assert RRule.retarget(fitted, opts) == {:ok, fitted}
    end

    test "flipping to all-day keeps the date the organiser picked, not the UTC one" do
      assert RRule.retarget("FREQ=DAILY;UNTIL=20260701T065959Z",
               all_day: true,
               timezone: "America/Los_Angeles"
             ) == {:ok, "FREQ=DAILY;UNTIL=20260630"}
    end

    test "the start-date check compares local dates" do
      assert RRule.retarget("FREQ=DAILY;UNTIL=20260701T065959Z",
               all_day: false,
               timezone: "America/Los_Angeles",
               start_date: ~D[2026-07-01]
             ) == {:error, :until_before_start}
    end
  end

  # The rule is only right if an expander stops where the organiser meant it to,
  # so these run the built rule through Tymeslot's own expander, which compares
  # instant against instant exactly as a compliant provider does.
  describe "a timed series ends on the date the organiser picked" do
    test "west of UTC, a late-day meeting keeps its final occurrence" do
      zone = "America/Los_Angeles"
      dates = occurrence_dates(~D[2026-06-25], ~T[17:30:00], zone, ~D[2026-06-30])

      assert dates == Enum.to_list(Date.range(~D[2026-06-25], ~D[2026-06-30]))
    end

    test "east of UTC, an early meeting gains no occurrence past the chosen date" do
      zone = "Pacific/Auckland"
      dates = occurrence_dates(~D[2026-06-25], ~T[09:00:00], zone, ~D[2026-06-30])

      assert dates == Enum.to_list(Date.range(~D[2026-06-25], ~D[2026-06-30]))
    end
  end

  # Expands a daily series starting at `time` local on `first_day` and ending on
  # `until`, and returns the local calendar date of every occurrence.
  defp occurrence_dates(first_day, time, zone, until) do
    start_at = DateTime.new!(first_day, time, zone)

    event = %{
      start_time: start_at,
      end_time: DateTime.add(start_at, 30, :minute),
      recurrence_rule: RRule.build(%{freq: :daily, until: until}, timezone: zone)
    }

    event
    |> RecurrenceExpander.expand(
      DateTime.add(start_at, -1, :day),
      DateTime.new!(Date.add(until, 30), ~T[00:00:00], "Etc/UTC")
    )
    |> Enum.map(&(&1.start_time |> DateTime.shift_zone!(zone) |> DateTime.to_date()))
  end

  describe "parse/2 — legacy UTC-stamped UNTIL" do
    # Rules written before UNTIL carried the event's timezone stamped the
    # organiser's local date with a literal end-of-day UTC. Read back through a
    # timezone, that instant lands on the next local day everywhere east of
    # UTC, silently extending the series — and an all-day toggle then rewrote
    # the rule with the extension baked in.
    for timezone <- [
          "Europe/Tallinn",
          "Asia/Kolkata",
          "Pacific/Auckland",
          "America/Los_Angeles",
          "Europe/London",
          "Etc/UTC"
        ] do
      test "reads as the date it spells in #{timezone}" do
        parsed = RRule.parse("FREQ=DAILY;UNTIL=20261231T235959Z", timezone: unquote(timezone))

        assert parsed[:until] == ~D[2026-12-31]
      end

      test "an all-day toggle in #{timezone} does not move the end date" do
        assert {:ok, rule} =
                 RRule.retarget("FREQ=DAILY;UNTIL=20261231T235959Z",
                   all_day: true,
                   timezone: unquote(timezone)
                 )

        assert rule == "FREQ=DAILY;UNTIL=20261231"
      end
    end

    test "a rule this module writes still round-trips to the date it was built from" do
      for timezone <- [
            "America/Los_Angeles",
            "Europe/Tallinn",
            "Pacific/Auckland",
            "Europe/London",
            "Etc/UTC"
          ] do
        rule = RRule.build(%{freq: :daily, until: ~D[2026-12-31]}, timezone: timezone)

        assert RRule.parse(rule, timezone: timezone)[:until] == ~D[2026-12-31],
               "#{timezone} did not round-trip (#{rule})"
      end
    end

    test "retarget is idempotent for a rule built in its own zone" do
      rule = RRule.build(%{freq: :daily, until: ~D[2026-12-31]}, timezone: "Pacific/Auckland")

      assert {:ok, once} = RRule.retarget(rule, all_day: false, timezone: "Pacific/Auckland")
      assert {:ok, twice} = RRule.retarget(once, all_day: false, timezone: "Pacific/Auckland")
      assert once == twice
    end
  end
end
