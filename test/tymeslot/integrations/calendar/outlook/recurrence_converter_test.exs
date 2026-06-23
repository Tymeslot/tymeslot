defmodule Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverterTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter

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
end
