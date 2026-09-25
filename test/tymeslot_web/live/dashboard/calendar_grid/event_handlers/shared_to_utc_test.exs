defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.SharedToUtcTest do
  @moduledoc """
  Unit tests for `Shared.to_utc/4` DST edge-case handling (issues #1 and #3).

  Uses real IANA timezone data (via Tz) — no mocking needed since these are
  pure data transformations. The dates are chosen to fall precisely in the
  known DST transition windows for each timezone.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  describe "to_utc/4 — normal (non-DST) times" do
    test "returns {:ok, utc_datetime} for a regular time" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-06-15], 10, 30, "Europe/London")
      assert dt.hour == 9
      assert dt.minute == 30
      assert dt.time_zone == "Etc/UTC"
    end

    test "returns {:ok, utc_datetime} for Etc/UTC with no conversion needed" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-06-15], 14, 0, "Etc/UTC")
      assert dt.hour == 14
      assert dt.minute == 0
      assert dt.time_zone == "Etc/UTC"
    end
  end

  describe "to_utc/4 — spring-forward gap (America/New_York, 2026-03-08 02:xx)" do
    # At 02:00 on 2026-03-08 the clock jumps to 03:00 (UTC-5 → UTC-4).
    # Times 02:00–02:59 do not exist in America/New_York that day.
    test "gap time returns {:ok, just_after} rather than crashing" do
      # 02:30 falls in the skipped hour — should resolve to 03:00 (just_after).
      result = Shared.to_utc(~D[2026-03-08], 2, 30, "America/New_York")
      assert {:ok, dt} = result
      # just_after is 03:00 EDT (UTC-4) = 07:00 UTC
      assert dt.hour == 7
      assert dt.minute == 0
      assert dt.time_zone == "Etc/UTC"
    end

    test "00:30 (before gap) is unaffected and resolves correctly" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-03-08], 0, 30, "America/New_York")
      # 00:30 EST (UTC-5) = 05:30 UTC
      assert dt.hour == 5
      assert dt.minute == 30
    end

    test "03:30 (after gap) resolves correctly" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-03-08], 3, 30, "America/New_York")
      # 03:30 EDT (UTC-4) = 07:30 UTC
      assert dt.hour == 7
      assert dt.minute == 30
    end
  end

  describe "to_utc/4 — fall-back ambiguity (America/New_York, 2026-11-01 01:xx)" do
    # At 02:00 on 2026-11-01 the clock falls back to 01:00 (UTC-4 → UTC-5).
    # Times 01:00–01:59 exist twice — once in EDT (UTC-4) and once in EST (UTC-5).
    test "ambiguous time returns {:ok, first (DST side)} rather than crashing" do
      # 01:30 is ambiguous; we expect the DST-side (first) = UTC-4 = 05:30 UTC.
      result = Shared.to_utc(~D[2026-11-01], 1, 30, "America/New_York")
      assert {:ok, dt} = result
      # first = EDT side (UTC-4): 01:30 EDT = 05:30 UTC
      assert dt.hour == 5
      assert dt.minute == 30
      assert dt.time_zone == "Etc/UTC"
    end
  end

  describe "to_utc/4 — compose_recurrence_rule integration (#12 UNTIL-before-start)" do
    test "compose_recurrence_rule returns {:error, :until_before_start} when until < start" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2025-01-01"}
      context = %{start_date: ~D[2026-06-01], all_day: false}
      assert {:error, :until_before_start} = Shared.compose_recurrence_rule(params, context)
    end

    test "compose_recurrence_rule returns a rule when until == start date" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2026-06-01"}
      context = %{start_date: ~D[2026-06-01], all_day: false}

      assert Shared.compose_recurrence_rule(params, context) ==
               "FREQ=WEEKLY;UNTIL=20260601T235959Z"
    end

    test "compose_recurrence_rule returns a rule when until > start date" do
      params = %{"freq" => "daily", "end_type" => "until", "until" => "2026-12-31"}
      context = %{start_date: ~D[2026-06-01], all_day: false}

      assert Shared.compose_recurrence_rule(params, context) ==
               "FREQ=DAILY;UNTIL=20261231T235959Z"
    end

    test "compose_recurrence_rule accepts no context (backward compatible)" do
      params = %{"freq" => "daily"}
      assert Shared.compose_recurrence_rule(params) == "FREQ=DAILY"
    end
  end

  describe "compose_recurrence_rule all-day UNTIL (#5)" do
    test "emits UNTIL as YYYYMMDD (no time) for all-day events" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2026-12-31"}
      context = %{all_day: true, start_date: ~D[2026-06-01]}
      assert Shared.compose_recurrence_rule(params, context) == "FREQ=WEEKLY;UNTIL=20261231"
    end

    test "emits UNTIL as UTC timestamp for timed events" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2026-12-31"}
      context = %{all_day: false, start_date: ~D[2026-06-01]}
      result = Shared.compose_recurrence_rule(params, context)
      assert String.contains?(result, "UNTIL=20261231T235959Z")
    end
  end

  describe "compose_recurrence_rule — a timed UNTIL ends the organiser's day" do
    @params %{"freq" => "daily", "end_type" => "until", "until" => "2026-06-30"}

    test "west of UTC the local day ends on the next UTC day" do
      context = %{all_day: false, start_date: ~D[2026-06-01], timezone: "America/Los_Angeles"}

      assert Shared.compose_recurrence_rule(@params, context) ==
               "FREQ=DAILY;UNTIL=20260701T065959Z"
    end

    test "east of UTC the local day ends earlier on the same UTC day" do
      context = %{all_day: false, start_date: ~D[2026-06-01], timezone: "Pacific/Auckland"}

      assert Shared.compose_recurrence_rule(@params, context) ==
               "FREQ=DAILY;UNTIL=20260630T115959Z"
    end

    test "an all-day series keeps its bare-date UNTIL whatever the timezone" do
      context = %{all_day: true, start_date: ~D[2026-06-01], timezone: "America/Los_Angeles"}

      assert Shared.compose_recurrence_rule(@params, context) == "FREQ=DAILY;UNTIL=20260630"
    end

    test "the composed rule reads back as the date the form supplied" do
      context = %{all_day: false, start_date: ~D[2026-06-01], timezone: "America/Los_Angeles"}
      rule = Shared.compose_recurrence_rule(@params, context)

      assert %{until: ~D[2026-06-30]} = RRule.parse(rule, timezone: "America/Los_Angeles")
    end
  end

  describe "recurrence_timezone/2" do
    test "an event's own timezone wins over the organiser's profile zone" do
      assert Shared.recurrence_timezone(
               %{timezone: "America/Los_Angeles"},
               "Europe/Tallinn"
             ) == "America/Los_Angeles"
    end

    test "an event carrying no timezone falls back to the organiser's" do
      assert Shared.recurrence_timezone(%{timezone: nil}, "Europe/Tallinn") == "Europe/Tallinn"
      assert Shared.recurrence_timezone(%{timezone: ""}, "Europe/Tallinn") == "Europe/Tallinn"
      assert Shared.recurrence_timezone(%{}, "Europe/Tallinn") == "Europe/Tallinn"
    end

    test "no event at all falls back to the organiser's" do
      assert Shared.recurrence_timezone(nil, "Europe/Tallinn") == "Europe/Tallinn"
    end
  end

  describe "a series ends its day on the calendar it sits on" do
    @cross_zone_params %{"freq" => "daily", "end_type" => "until", "until" => "2026-12-31"}

    # A Tallinn organiser editing a Los Angeles series. Ending the day in the
    # profile zone puts UNTIL at 21:59:59Z, which is 13:59 in Los Angeles and
    # cuts that day's afternoon occurrences; the event's own zone ends it at
    # 23:59:59 local, 07:59:59Z the next day.
    test "the event's zone ends the day, not the organiser's" do
      event = %{timezone: "America/Los_Angeles"}

      context = %{
        all_day: false,
        start_date: ~D[2026-06-01],
        timezone: Shared.recurrence_timezone(event, "Europe/Tallinn")
      }

      assert Shared.compose_recurrence_rule(@cross_zone_params, context) ==
               "FREQ=DAILY;UNTIL=20270101T075959Z"
    end

    test "the organiser's zone still ends the day for an event that has none" do
      context = %{
        all_day: false,
        start_date: ~D[2026-06-01],
        timezone: Shared.recurrence_timezone(%{timezone: nil}, "Europe/Tallinn")
      }

      assert Shared.compose_recurrence_rule(@cross_zone_params, context) ==
               "FREQ=DAILY;UNTIL=20261231T215959Z"
    end
  end
end
