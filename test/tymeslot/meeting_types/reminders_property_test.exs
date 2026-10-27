defmodule Tymeslot.MeetingTypes.RemindersPropertyTest do
  @moduledoc """
  Property-based tests for Reminders.
  """
  use ExUnit.Case, async: true
  @moduletag :utils
  use ExUnitProperties

  alias Tymeslot.MeetingTypes.Reminders

  describe "normalize_reminder/1" do
    property "is idempotent for valid reminders" do
      check all(
              value <- integer(1..1000),
              unit <- member_of(["minutes", "hours", "days"])
            ) do
        {:ok, first} = Reminders.normalize_reminder(%{value: value, unit: unit})
        {:ok, second} = Reminders.normalize_reminder(first)

        assert first == second
      end
    end

    property "string-keyed maps normalise to the same result as atom-keyed" do
      check all(
              value <- integer(1..1000),
              unit <- member_of(["minutes", "hours", "days"])
            ) do
        {:ok, from_atom} = Reminders.normalize_reminder(%{value: value, unit: unit})
        {:ok, from_string} = Reminders.normalize_reminder(%{"value" => value, "unit" => unit})

        assert from_atom == from_string
      end
    end

    property "invalid units always return error" do
      check all(
              value <- integer(1..100),
              unit <- string(:alphanumeric, min_length: 1, max_length: 10),
              unit not in ["minutes", "hours", "days"]
            ) do
        assert {:error, :invalid_reminder} =
                 Reminders.normalize_reminder(%{value: value, unit: unit})
      end
    end
  end

  describe "duplicate_reminders?/1" do
    property "equivalent intervals are detected as duplicates" do
      check all(hours <- integer(1..24)) do
        reminders = [
          %{value: hours, unit: "hours"},
          %{value: hours * 60, unit: "minutes"}
        ]

        assert Reminders.duplicate_reminders?(reminders)
      end
    end

    property "days and hours equivalence is detected" do
      check all(days <- integer(1..7)) do
        reminders = [
          %{value: days, unit: "days"},
          %{value: days * 24, unit: "hours"}
        ]

        assert Reminders.duplicate_reminders?(reminders)
      end
    end

    property "distinct intervals are not duplicates" do
      check all(
              v1 <- integer(1..100),
              v2 <- integer(1..100),
              v1 != v2
            ) do
        reminders = [
          %{value: v1, unit: "minutes"},
          %{value: v2, unit: "minutes"}
        ]

        refute Reminders.duplicate_reminders?(reminders)
      end
    end
  end

  describe "reminder_interval_seconds/2" do
    property "minutes conversion is exact" do
      check all(value <- integer(1..1000)) do
        assert Reminders.reminder_interval_seconds(value, "minutes") == value * 60
      end
    end

    property "hours conversion is exact" do
      check all(value <- integer(1..1000)) do
        assert Reminders.reminder_interval_seconds(value, "hours") == value * 3600
      end
    end

    property "days conversion is exact" do
      check all(value <- integer(1..365)) do
        assert Reminders.reminder_interval_seconds(value, "days") == value * 86_400
      end
    end

    property "string values parse identically to integer values" do
      check all(
              value <- integer(1..1000),
              unit <- member_of(["minutes", "hours", "days"])
            ) do
        assert Reminders.reminder_interval_seconds(value, unit) ==
                 Reminders.reminder_interval_seconds(to_string(value), unit)
      end
    end
  end

  describe "parse_reminder_value/1" do
    property "integers pass through unchanged" do
      check all(value <- integer(1..10_000)) do
        assert Reminders.parse_reminder_value(value) == value
      end
    end

    property "string integers parse correctly" do
      check all(value <- integer(1..10_000)) do
        assert Reminders.parse_reminder_value(to_string(value)) == value
      end
    end

    property "strings with trailing text still parse the leading integer" do
      check all(
              value <- integer(1..1000),
              suffix <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        assert Reminders.parse_reminder_value("#{value} #{suffix}") == value
      end
    end

    property "non-positive integers default to 30" do
      check all(value <- integer(-1000..0)) do
        assert Reminders.parse_reminder_value(value) == 30
      end
    end
  end
end
