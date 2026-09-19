defmodule Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverterTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  @start_date ~D[2026-06-15]

  describe "rrule_to_outlook/2 — pattern" do
    test "daily pattern" do
      %{"pattern" => pattern} = RecurrenceConverter.rrule_to_outlook("FREQ=DAILY", @start_date)
      assert pattern["type"] == "daily"
      assert pattern["interval"] == 1
    end

    test "daily pattern carries interval" do
      %{"pattern" => pattern} =
        RecurrenceConverter.rrule_to_outlook("FREQ=DAILY;INTERVAL=3", @start_date)

      assert pattern["interval"] == 3
    end

    test "weekly pattern with daysOfWeek" do
      %{"pattern" => pattern} =
        RecurrenceConverter.rrule_to_outlook("FREQ=WEEKLY;BYDAY=MO,WE", @start_date)

      assert pattern["type"] == "weekly"
      assert pattern["daysOfWeek"] == ["monday", "wednesday"]
    end

    test "weekly pattern without BYDAY falls back to the start date's weekday" do
      # 2026-06-15 is a Monday
      %{"pattern" => pattern} =
        RecurrenceConverter.rrule_to_outlook("FREQ=WEEKLY", @start_date)

      assert pattern["type"] == "weekly"
      assert pattern["daysOfWeek"] == ["monday"]
    end

    test "monthly pattern is absoluteMonthly anchored on the start day" do
      %{"pattern" => pattern} =
        RecurrenceConverter.rrule_to_outlook("FREQ=MONTHLY", @start_date)

      assert pattern["type"] == "absoluteMonthly"
      assert pattern["dayOfMonth"] == 15
    end

    test "yearly pattern is absoluteYearly anchored on the start month and day" do
      %{"pattern" => pattern} =
        RecurrenceConverter.rrule_to_outlook("FREQ=YEARLY", @start_date)

      assert pattern["type"] == "absoluteYearly"
      assert pattern["dayOfMonth"] == 15
      assert pattern["month"] == 6
    end
  end

  describe "rrule_to_outlook/2 — range" do
    test "noEnd range when neither COUNT nor UNTIL present" do
      %{"range" => range} = RecurrenceConverter.rrule_to_outlook("FREQ=DAILY", @start_date)
      assert range["type"] == "noEnd"
      assert range["startDate"] == "2026-06-15"
    end

    test "numbered range from COUNT" do
      %{"range" => range} =
        RecurrenceConverter.rrule_to_outlook("FREQ=DAILY;COUNT=10", @start_date)

      assert range["type"] == "numbered"
      assert range["numberOfOccurrences"] == 10
    end

    test "endDate range from UNTIL" do
      %{"range" => range} =
        RecurrenceConverter.rrule_to_outlook("FREQ=WEEKLY;UNTIL=20261231T235959Z", @start_date)

      assert range["type"] == "endDate"
      assert range["endDate"] == "2026-12-31"
    end
  end

  describe "outlook_to_rrule/1" do
    test "converts a daily pattern" do
      recurrence = %{
        "pattern" => %{"type" => "daily", "interval" => 2},
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=DAILY;INTERVAL=2"
    end

    test "converts a weekly pattern with daysOfWeek" do
      recurrence = %{
        "pattern" => %{
          "type" => "weekly",
          "interval" => 1,
          "daysOfWeek" => ["monday", "wednesday", "friday"]
        },
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=WEEKLY;BYDAY=MO,WE,FR"
    end

    test "converts absoluteMonthly to MONTHLY" do
      recurrence = %{
        "pattern" => %{"type" => "absoluteMonthly", "interval" => 1, "dayOfMonth" => 15},
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=MONTHLY"
    end

    test "converts absoluteYearly to YEARLY" do
      recurrence = %{
        "pattern" => %{"type" => "absoluteYearly", "interval" => 1},
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=YEARLY"
    end

    test "converts a numbered range to COUNT" do
      recurrence = %{
        "pattern" => %{"type" => "daily", "interval" => 1},
        "range" => %{"type" => "numbered", "numberOfOccurrences" => 5}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=DAILY;COUNT=5"
    end

    test "converts an endDate range to UNTIL" do
      recurrence = %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["tuesday"]},
        "range" => %{"type" => "endDate", "endDate" => "2026-12-31"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) ==
               "FREQ=WEEKLY;BYDAY=TU;UNTIL=20261231T235959Z"
    end

    test "returns nil for an unrecognised map" do
      assert RecurrenceConverter.outlook_to_rrule(%{}) == nil
      assert RecurrenceConverter.outlook_to_rrule(nil) == nil
    end
  end

  describe "round-trip rrule -> outlook -> rrule" do
    for rrule <- [
          "FREQ=DAILY;INTERVAL=3",
          "FREQ=WEEKLY;BYDAY=MO,WE,FR",
          "FREQ=DAILY;COUNT=10",
          "FREQ=WEEKLY;BYDAY=TU;UNTIL=20261231T235959Z"
        ] do
      test "round-trips #{rrule}" do
        rrule = unquote(rrule)
        outlook = RecurrenceConverter.rrule_to_outlook(rrule, ~D[2026-06-16])
        assert RecurrenceConverter.outlook_to_rrule(outlook) == rrule
      end
    end
  end

  describe "rrule_to_outlook/3 — endDate is the organiser's local date" do
    # Graph reads `endDate` as a local date in the event's own timezone (its
    # default when no `recurrenceTimeZone` is sent, which this converter never
    # sends), while a timed rule's UNTIL is an instant in UTC. Parsing the rule
    # without the zone read that instant as a UTC date, so an organiser west of
    # UTC had the series written one day late and Graph generated an extra
    # occurrence.
    for {timezone, until} <- [
          {"America/Los_Angeles", "20270101T075959Z"},
          {"America/New_York", "20270101T045959Z"},
          {"Europe/Tallinn", "20261231T215959Z"},
          {"Pacific/Auckland", "20261231T105959Z"},
          {"Etc/UTC", "20261231T235959Z"}
        ] do
      test "#{timezone} ends on the date the organiser picked" do
        rrule = "FREQ=DAILY;UNTIL=#{unquote(until)}"

        %{"range" => range} =
          RecurrenceConverter.rrule_to_outlook(rrule, @start_date, unquote(timezone))

        assert range["endDate"] == "2026-12-31"
      end
    end

    test "a rule built for a zone converts back to the date that built it" do
      for timezone <- ["America/Los_Angeles", "Europe/Tallinn", "Pacific/Auckland"] do
        rrule = RRule.build(%{freq: :daily, until: ~D[2026-12-31]}, timezone: timezone)

        %{"range" => range} =
          RecurrenceConverter.rrule_to_outlook(rrule, @start_date, timezone)

        assert range["endDate"] == "2026-12-31", "wrong endDate for #{timezone}"
      end
    end

    test "a legacy UTC-stamped rule keeps its date in every zone" do
      for timezone <- ["America/Los_Angeles", "Europe/Tallinn", "Pacific/Auckland", nil] do
        %{"range" => range} =
          RecurrenceConverter.rrule_to_outlook(
            "FREQ=DAILY;UNTIL=20261231T235959Z",
            @start_date,
            timezone
          )

        assert range["endDate"] == "2026-12-31", "wrong endDate for #{inspect(timezone)}"
      end
    end
  end
end
