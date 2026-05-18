defmodule Tymeslot.Integrations.Calendar.ICalBuilderRecurrenceTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder

  describe "build_rrule/1" do
    test "returns nil for nil input" do
      assert ICalBuilder.build_rrule(nil) == nil
    end

    test "builds simple DAILY recurrence" do
      recurrence = %{frequency: "DAILY"}

      rrule = ICalBuilder.build_rrule(recurrence)

      assert rrule == "RRULE:FREQ=DAILY"
    end

    test "builds WEEKLY recurrence with days" do
      recurrence = %{
        frequency: "WEEKLY",
        by_day: ["MO", "WE", "FR"]
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert rrule == "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"
    end

    test "includes interval when greater than 1" do
      recurrence = %{
        frequency: "WEEKLY",
        interval: 2
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "INTERVAL=2")
    end

    test "includes count when provided" do
      recurrence = %{
        frequency: "DAILY",
        count: 10
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "COUNT=10")
    end

    test "includes until date when provided" do
      until_date = ~U[2024-12-31 23:59:59Z]

      recurrence = %{
        frequency: "WEEKLY",
        until: until_date
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "UNTIL=")
      assert String.contains?(rrule, "20241231T235959Z")
    end

    test "includes by_month when provided" do
      recurrence = %{
        frequency: "YEARLY",
        by_month: [1, 6, 12]
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "BYMONTH=1,6,12")
    end

    test "builds complex recurrence rule" do
      recurrence = %{
        frequency: "MONTHLY",
        interval: 2,
        count: 12,
        by_day: ["MO"]
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "FREQ=MONTHLY")
      assert String.contains?(rrule, "INTERVAL=2")
      assert String.contains?(rrule, "COUNT=12")
      assert String.contains?(rrule, "BYDAY=MO")
    end
  end
end
