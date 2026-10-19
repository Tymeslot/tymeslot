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

  describe "options/2" do
    test "parses frequency" do
      assert %{freq: :weekly} = RRule.options("FREQ=WEEKLY")
    end

    test "parses interval" do
      assert %{freq: :daily, interval: 2} = RRule.options("FREQ=DAILY;INTERVAL=2")
    end

    test "parses by_day into atoms" do
      assert %{freq: :weekly, by_day: [:mo, :we, :fr]} =
               RRule.options("FREQ=WEEKLY;BYDAY=MO,WE,FR")
    end

    test "parses count" do
      assert %{freq: :daily, count: 10} = RRule.options("FREQ=DAILY;COUNT=10")
    end

    test "parses until from a date-time stamp" do
      assert %{freq: :weekly, until: ~D[2026-12-31]} =
               RRule.options("FREQ=WEEKLY;UNTIL=20261231T235959Z")
    end

    test "parses until from a bare date stamp" do
      assert %{until: ~D[2026-12-31]} = RRule.options("FREQ=WEEKLY;UNTIL=20261231")
    end

    test "is lenient about a leading RRULE: prefix" do
      assert %{freq: :weekly} = RRule.options("RRULE:FREQ=WEEKLY")
    end

    test "ignores unknown tokens" do
      assert %{freq: :weekly} = RRule.options("FREQ=WEEKLY;BYSETPOS=1;WKST=MO")
    end

    test "returns an empty map for a blank string" do
      assert RRule.options("") == %{}
    end

    test "defaults a missing interval to absent rather than 1" do
      refute Map.has_key?(RRule.options("FREQ=WEEKLY"), :interval)
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

    test "all-day UNTIL round-trips through options/2 correctly" do
      rrule = RRule.build(%{freq: :weekly, until: ~D[2027-01-15]}, all_day: true)
      parsed = RRule.options(rrule)
      assert parsed.until == ~D[2027-01-15]
    end
  end

  describe "round-trip build ∘ options" do
    for rule <- [
          %{freq: :daily},
          %{freq: :weekly, interval: 2, by_day: [:mo, :we, :fr]},
          %{freq: :monthly, interval: 1, count: 6},
          %{freq: :yearly, until: ~D[2030-06-15]},
          %{freq: :weekly, by_day: [:sa, :su], count: 3}
        ] do
      test "round-trips #{inspect(rule)}" do
        rule = unquote(Macro.escape(rule))
        rebuilt = rule |> RRule.build() |> RRule.options() |> RRule.build()
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

  describe "options/2 — a timed UNTIL reads back as the organiser's local date" do
    test "west of UTC" do
      assert %{until: ~D[2026-06-30]} =
               RRule.options("FREQ=DAILY;UNTIL=20260701T065959Z", timezone: "America/Los_Angeles")
    end

    test "east of UTC" do
      assert %{until: ~D[2026-06-30]} =
               RRule.options("FREQ=DAILY;UNTIL=20260630T115959Z", timezone: "Pacific/Auckland")
    end

    test "a bare-date UNTIL is zone-free and reads as it is written" do
      assert %{until: ~D[2026-06-30]} =
               RRule.options("FREQ=DAILY;UNTIL=20260630", timezone: "Pacific/Auckland")
    end

    test "without a timezone the UTC day is used, as before" do
      assert %{until: ~D[2026-07-01]} = RRule.options("FREQ=DAILY;UNTIL=20260701T065959Z")
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

  describe "options/2 — legacy UTC-stamped UNTIL" do
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
        parsed = RRule.options("FREQ=DAILY;UNTIL=20261231T235959Z", timezone: unquote(timezone))

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

        assert RRule.options(rule, timezone: timezone)[:until] == ~D[2026-12-31],
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

  describe "end_before/2" do
    test "an all-day rule ends the day before, as a date" do
      assert RRule.end_before("FREQ=WEEKLY;COUNT=10", ~D[2026-01-26]) ==
               "FREQ=WEEKLY;UNTIL=20260125"
    end

    test "a zoned or UTC rule ends a second before the instant, in UTC" do
      boundary = DateTime.new!(~D[2026-01-26], ~T[10:00:00], "Europe/Berlin")

      assert RRule.end_before("FREQ=WEEKLY;UNTIL=20261231T225959Z;BYDAY=MO", boundary) ==
               "FREQ=WEEKLY;UNTIL=20260126T085959Z;BYDAY=MO"
    end

    test "a floating rule ends a second before the wall clock, with no zone" do
      assert RRule.end_before("RRULE:FREQ=DAILY", ~N[2026-01-26 10:00:00]) ==
               "RRULE:FREQ=DAILY;UNTIL=20260126T095959"
    end

    test "a rule stating both ends keeps one" do
      assert RRule.end_before("FREQ=DAILY;COUNT=3;INTERVAL=2;UNTIL=20270101", ~D[2026-02-01]) ==
               "FREQ=DAILY;UNTIL=20260131;INTERVAL=2"
    end
  end

  describe "reduce_count/2" do
    test "takes the occurrences off the COUNT, in place" do
      assert RRule.reduce_count("FREQ=WEEKLY;COUNT=10;BYDAY=MO", 3) ==
               "FREQ=WEEKLY;COUNT=7;BYDAY=MO"
    end

    test "leaves a rule with no COUNT as it is" do
      assert RRule.reduce_count("FREQ=WEEKLY;UNTIL=20261231", 3) == "FREQ=WEEKLY;UNTIL=20261231"
    end
  end

  describe "parse/1" do
    test "reads every part the expander follows" do
      assert {:ok,
              %RRule{
                freq: :monthly,
                interval: 2,
                count: 10,
                by_day: [{2, 2}, {-1, 5}],
                by_month_day: [1, -1],
                by_month: [3, 9],
                by_set_pos: [-1],
                week_start: 7,
                other: []
              }} =
               RRule.parse(
                 "FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=2TU,-1FR;BYMONTHDAY=1,-1;" <>
                   "BYMONTH=3,9;BYSETPOS=-1;WKST=SU"
               )
    end

    test "defaults INTERVAL to 1 and leaves an unstated WKST unset" do
      assert {:ok, %RRule{interval: 1, week_start: nil}} = RRule.parse("RRULE:FREQ=DAILY")
    end

    test "keeps UNTIL as written" do
      assert {:ok, %RRule{until: "20260411T000000"}} =
               RRule.parse("FREQ=WEEKLY;UNTIL=20260411T000000")
    end

    test "keeps the parts it does not follow, in the order written" do
      assert {:ok, %RRule{other: [{"BYHOUR", "9,17"}, {"BYYEARDAY", "1"}]}} =
               RRule.parse("FREQ=YEARLY;BYHOUR=9,17;BYDAY=MO;BYYEARDAY=1")
    end

    test "refuses a rule without a known FREQ, or one that never moves forward" do
      for rule <- ["", "BYDAY=MO", "FREQ=HOURLY", "FREQ=DAILY;INTERVAL=0"] do
        assert RRule.parse(rule) == :error
      end
    end
  end

  describe "format/1" do
    test "writes a parsed rule back with the parts it does not follow unchanged" do
      for rule <- [
            "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=SU;COUNT=8",
            "FREQ=MONTHLY;BYDAY=2TU,-1FR;BYHOUR=9;X-NAME=kept",
            "FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=2,3,4,5,6,7,8;BYDAY=TU;UNTIL=20301231T235959Z"
          ] do
        {:ok, parsed} = RRule.parse(rule)
        assert {:ok, ^parsed} = parsed |> RRule.format() |> RRule.parse()
      end

      {:ok, parsed} = RRule.parse("RRULE:FREQ=MONTHLY;BYDAY=2TU;BYHOUR=9;X-NAME=kept")
      assert RRule.format(parsed) == "FREQ=MONTHLY;BYDAY=2TU;BYHOUR=9;X-NAME=kept"
    end
  end

  describe "until_instant/2" do
    test "reads a UTC UNTIL as the instant it is" do
      assert until("20260411T120000Z", "Pacific/Auckland") == ~U[2026-04-11 12:00:00Z]
    end

    test "reads a floating UNTIL as a wall clock in the series' zone" do
      assert until("20260411T090000", "Pacific/Honolulu") == ~U[2026-04-11 19:00:00Z]
    end

    test "reads a bare date as the end of that day in the series' zone" do
      assert until("20260411", "Pacific/Auckland") == ~U[2026-04-11 11:59:59Z]
      assert until("20260411", "Etc/UTC") == ~U[2026-04-11 23:59:59Z]
    end

    test "reads the legacy end-of-day UTC stamp as the end of the date it spells" do
      assert until("20260411T235959Z", "Pacific/Honolulu") == ~U[2026-04-12 09:59:59Z]
    end

    test "leaves a rule without a readable UNTIL unbounded" do
      for rule <- ["FREQ=DAILY;UNTIL=soon", "FREQ=DAILY"] do
        assert {:ok, parsed} = RRule.parse(rule)
        assert RRule.until_instant(parsed, "Etc/UTC") == nil
      end
    end

    defp until(value, zone) do
      {:ok, rule} = RRule.parse("FREQ=DAILY;UNTIL=" <> value)
      rule |> RRule.until_instant(zone) |> DateTime.shift_zone!("Etc/UTC")
    end
  end

  describe "build/2 keeping the parts of the rule being edited" do
    test "keeps what the editor does not show while the frequency stays" do
      assert RRule.build(%{freq: :monthly, interval: 3},
               keep: "FREQ=MONTHLY;BYDAY=2TU;BYSETPOS=1;WKST=SU;BYHOUR=9;COUNT=5"
             ) == "FREQ=MONTHLY;INTERVAL=3;BYDAY=2TU;BYSETPOS=1;WKST=SU;BYHOUR=9"
    end

    test "takes a weekly rule's days from the editor" do
      assert RRule.build(%{freq: :weekly, by_day: [:tu]},
               keep: "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;X-NAME=kept"
             ) == "FREQ=WEEKLY;BYDAY=TU;X-NAME=kept"
    end

    test "drops a weekly rule's BYSETPOS once the editor gives its days" do
      assert RRule.build(%{freq: :weekly, by_day: [:mo, :we, :fr]},
               keep: "FREQ=WEEKLY;BYDAY=MO,WE;BYSETPOS=1"
             ) == "FREQ=WEEKLY;BYDAY=MO,WE,FR"

      assert RRule.build(%{freq: :weekly}, keep: "FREQ=WEEKLY;BYDAY=MO,WE;BYSETPOS=1") ==
               "FREQ=WEEKLY"
    end

    test "never keeps a BYSETPOS with no other BY part to pick among" do
      assert RRule.build(%{freq: :monthly}, keep: "FREQ=MONTHLY;BYSETPOS=-1;X-NAME=kept") ==
               "FREQ=MONTHLY;X-NAME=kept"
    end

    test "drops the old period's BY parts when the frequency changes" do
      assert RRule.build(%{freq: :weekly, count: 4},
               keep: "FREQ=MONTHLY;BYDAY=2TU;BYMONTHDAY=8;BYHOUR=9;WKST=SU;X-NAME=kept"
             ) == "FREQ=WEEKLY;WKST=SU;X-NAME=kept;COUNT=4"
    end

    test "builds from the options alone without a rule to keep from" do
      assert RRule.build(%{freq: :daily}, keep: nil) == "FREQ=DAILY"
      assert RRule.build(%{freq: :daily}, keep: "FREQ=SOMETIMES") == "FREQ=DAILY"
    end
  end

  # The expander and the recurrence editor read UNTIL in the same zone, so the
  # last occurrence the expander makes falls on the date the editor shows.
  # The far east (UTC+12/13) and far west (UTC-10) are where a UTC reading
  # moves the last occurrence onto another day.
  describe "the last occurrence falls on the editor's end date" do
    for zone <- ["Pacific/Auckland", "Pacific/Honolulu"],
        {form, rule} <- [
          {"written by the editor", :built},
          {"floating", "FREQ=DAILY;UNTIL=20260415T235959"},
          {"a bare date", "FREQ=DAILY;UNTIL=20260415"},
          {"the legacy end-of-day UTC stamp", "FREQ=DAILY;UNTIL=20260415T235959Z"}
        ] do
      @zone zone
      @rule rule

      test "#{form}, in #{zone}" do
        rule =
          if @rule == :built,
            do: RRule.build(%{freq: :daily, until: ~D[2026-04-15]}, timezone: @zone),
            else: @rule

        assert %{until: ~D[2026-04-15]} = RRule.options(rule, timezone: @zone)

        # Early and late in the day, where a UTC reading would cross the date.
        for time <- [~T[00:30:00], ~T[23:30:00]] do
          start = DateTime.new!(~D[2026-04-10], time, @zone)

          last =
            %{start_time: start, end_time: DateTime.add(start, 1800), recurrence_rule: rule}
            |> RecurrenceExpander.expand(start, DateTime.add(start, 30, :day))
            |> List.last()

          assert last.start_time |> DateTime.shift_zone!(@zone) |> DateTime.to_date() ==
                   ~D[2026-04-15]
        end
      end
    end
  end
end
