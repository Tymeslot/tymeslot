defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.RecurrenceFieldsTest do
  @moduledoc """
  Unit tests for `RecurrenceFields.compose_recurrence_rule/2` and
  `RecurrenceFields.recurrence_timezone/2`: UNTIL validation against the
  event start, value types, and the zone a series ends its day in.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.RecurrenceFields

  describe "compose_recurrence_rule integration (#12 UNTIL-before-start)" do
    test "compose_recurrence_rule returns {:error, :until_before_start} when until < start" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2025-01-01"}
      context = %{start_date: ~D[2026-06-01], all_day: false}

      assert {:error, :until_before_start} =
               RecurrenceFields.compose_recurrence_rule(params, context)
    end

    test "compose_recurrence_rule returns a rule when until == start date" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2026-06-01"}
      context = %{start_date: ~D[2026-06-01], all_day: false}

      assert RecurrenceFields.compose_recurrence_rule(params, context) ==
               "FREQ=WEEKLY;UNTIL=20260601T235959Z"
    end

    test "compose_recurrence_rule returns a rule when until > start date" do
      params = %{"freq" => "daily", "end_type" => "until", "until" => "2026-12-31"}
      context = %{start_date: ~D[2026-06-01], all_day: false}

      assert RecurrenceFields.compose_recurrence_rule(params, context) ==
               "FREQ=DAILY;UNTIL=20261231T235959Z"
    end

    test "compose_recurrence_rule accepts no context (backward compatible)" do
      params = %{"freq" => "daily"}
      assert RecurrenceFields.compose_recurrence_rule(params) == "FREQ=DAILY"
    end
  end

  # The editor shows the number or date field only once its end is picked,
  # so the pick arrives without one.
  describe "compose_recurrence_rule with an end picked before its value" do
    test "ends after the default count" do
      params = %{"freq" => "weekly", "end_type" => "count"}
      context = %{start_date: ~D[2026-06-01], all_day: true}
      assert RecurrenceFields.compose_recurrence_rule(params, context) == "FREQ=WEEKLY;COUNT=10"
    end

    test "ends on the day of the tenth occurrence" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => ""}
      context = %{start_date: ~D[2026-06-01], all_day: true}

      assert RecurrenceFields.compose_recurrence_rule(params, context) ==
               "FREQ=WEEKLY;UNTIL=20260803"
    end

    test "takes an interval and a count no larger than the editor's fields allow" do
      params = %{
        "freq" => "daily",
        "interval" => "5000",
        "end_type" => "count",
        "count" => "5000"
      }

      context = %{start_date: ~D[2026-06-01], all_day: true}

      assert RecurrenceFields.compose_recurrence_rule(params, context) ==
               "FREQ=DAILY;INTERVAL=999;COUNT=999"
    end
  end

  describe "compose_recurrence_rule all-day UNTIL (#5)" do
    test "emits UNTIL as YYYYMMDD (no time) for all-day events" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2026-12-31"}
      context = %{all_day: true, start_date: ~D[2026-06-01]}

      assert RecurrenceFields.compose_recurrence_rule(params, context) ==
               "FREQ=WEEKLY;UNTIL=20261231"
    end

    test "emits UNTIL as UTC timestamp for timed events" do
      params = %{"freq" => "weekly", "end_type" => "until", "until" => "2026-12-31"}
      context = %{all_day: false, start_date: ~D[2026-06-01]}
      result = RecurrenceFields.compose_recurrence_rule(params, context)
      assert String.contains?(result, "UNTIL=20261231T235959Z")
    end
  end

  describe "compose_recurrence_rule — a timed UNTIL ends the organiser's day" do
    @params %{"freq" => "daily", "end_type" => "until", "until" => "2026-06-30"}

    test "west of UTC the local day ends on the next UTC day" do
      context = %{all_day: false, start_date: ~D[2026-06-01], timezone: "America/Los_Angeles"}

      assert RecurrenceFields.compose_recurrence_rule(@params, context) ==
               "FREQ=DAILY;UNTIL=20260701T065959Z"
    end

    test "east of UTC the local day ends earlier on the same UTC day" do
      context = %{all_day: false, start_date: ~D[2026-06-01], timezone: "Pacific/Auckland"}

      assert RecurrenceFields.compose_recurrence_rule(@params, context) ==
               "FREQ=DAILY;UNTIL=20260630T115959Z"
    end

    test "an all-day series keeps its bare-date UNTIL whatever the timezone" do
      context = %{all_day: true, start_date: ~D[2026-06-01], timezone: "America/Los_Angeles"}

      assert RecurrenceFields.compose_recurrence_rule(@params, context) ==
               "FREQ=DAILY;UNTIL=20260630"
    end

    test "the composed rule reads back as the date the form supplied" do
      context = %{all_day: false, start_date: ~D[2026-06-01], timezone: "America/Los_Angeles"}
      rule = RecurrenceFields.compose_recurrence_rule(@params, context)

      assert %{until: ~D[2026-06-30]} = RRule.options(rule, timezone: "America/Los_Angeles")
    end
  end

  describe "recurrence_timezone/2" do
    test "an event's own timezone wins over the organiser's profile zone" do
      assert RecurrenceFields.recurrence_timezone(
               %{timezone: "America/Los_Angeles"},
               "Europe/Tallinn"
             ) == "America/Los_Angeles"
    end

    test "an event carrying no timezone falls back to the organiser's" do
      assert RecurrenceFields.recurrence_timezone(%{timezone: nil}, "Europe/Tallinn") ==
               "Europe/Tallinn"

      assert RecurrenceFields.recurrence_timezone(%{timezone: ""}, "Europe/Tallinn") ==
               "Europe/Tallinn"

      assert RecurrenceFields.recurrence_timezone(%{}, "Europe/Tallinn") == "Europe/Tallinn"
    end

    # Sync stores UTC for any event written with UTC times, which says how a
    # one-off was written rather than which local time a series made from it
    # keeps.
    test "a one-off carrying UTC falls back to the organiser's" do
      for zone <- ["Etc/UTC", "UTC", "GMT"], rule <- [nil, ""] do
        assert RecurrenceFields.recurrence_timezone(
                 %{timezone: zone, recurrence_rule: rule},
                 "Europe/Tallinn"
               ) == "Europe/Tallinn"
      end
    end

    # Its writers read an UNTIL back as a date in the series' own zone.
    test "a series carrying UTC keeps it" do
      assert RecurrenceFields.recurrence_timezone(
               %{timezone: "Etc/UTC", recurrence_rule: "FREQ=WEEKLY"},
               "America/Los_Angeles"
             ) == "Etc/UTC"
    end

    test "no event at all falls back to the organiser's" do
      assert RecurrenceFields.recurrence_timezone(nil, "Europe/Tallinn") == "Europe/Tallinn"
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
        timezone: RecurrenceFields.recurrence_timezone(event, "Europe/Tallinn")
      }

      assert RecurrenceFields.compose_recurrence_rule(@cross_zone_params, context) ==
               "FREQ=DAILY;UNTIL=20270101T075959Z"
    end

    test "the organiser's zone still ends the day for an event that has none" do
      context = %{
        all_day: false,
        start_date: ~D[2026-06-01],
        timezone: RecurrenceFields.recurrence_timezone(%{timezone: nil}, "Europe/Tallinn")
      }

      assert RecurrenceFields.compose_recurrence_rule(@cross_zone_params, context) ==
               "FREQ=DAILY;UNTIL=20261231T215959Z"
    end
  end
end
