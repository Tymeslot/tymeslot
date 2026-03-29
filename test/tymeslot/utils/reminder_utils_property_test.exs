defmodule Tymeslot.Utils.ReminderUtilsPropertyTest do
  @moduledoc """
  Property-based tests for ReminderUtils.
  """
  use ExUnit.Case, async: true
  @moduletag :utils
  use ExUnitProperties

  alias Tymeslot.Utils.ReminderUtils

  describe "normalize_reminder/1" do
    property "is idempotent for valid reminders" do
      check all(
              value <- integer(1..1000),
              unit <- member_of(["minutes", "hours", "days"])
            ) do
        {:ok, first} = ReminderUtils.normalize_reminder(%{value: value, unit: unit})
        {:ok, second} = ReminderUtils.normalize_reminder(first)

        assert first == second
      end
    end

    property "string-keyed maps normalise to the same result as atom-keyed" do
      check all(
              value <- integer(1..1000),
              unit <- member_of(["minutes", "hours", "days"])
            ) do
        {:ok, from_atom} = ReminderUtils.normalize_reminder(%{value: value, unit: unit})
        {:ok, from_string} = ReminderUtils.normalize_reminder(%{"value" => value, "unit" => unit})

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
                 ReminderUtils.normalize_reminder(%{value: value, unit: unit})
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

        assert ReminderUtils.duplicate_reminders?(reminders)
      end
    end

    property "days and hours equivalence is detected" do
      check all(days <- integer(1..7)) do
        reminders = [
          %{value: days, unit: "days"},
          %{value: days * 24, unit: "hours"}
        ]

        assert ReminderUtils.duplicate_reminders?(reminders)
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

        refute ReminderUtils.duplicate_reminders?(reminders)
      end
    end
  end

  describe "reminder_interval_seconds/2" do
    property "minutes conversion is exact" do
      check all(value <- integer(1..1000)) do
        assert ReminderUtils.reminder_interval_seconds(value, "minutes") == value * 60
      end
    end

    property "hours conversion is exact" do
      check all(value <- integer(1..1000)) do
        assert ReminderUtils.reminder_interval_seconds(value, "hours") == value * 3600
      end
    end

    property "days conversion is exact" do
      check all(value <- integer(1..365)) do
        assert ReminderUtils.reminder_interval_seconds(value, "days") == value * 86_400
      end
    end

    property "string values parse identically to integer values" do
      check all(
              value <- integer(1..1000),
              unit <- member_of(["minutes", "hours", "days"])
            ) do
        assert ReminderUtils.reminder_interval_seconds(value, unit) ==
                 ReminderUtils.reminder_interval_seconds(to_string(value), unit)
      end
    end
  end

  describe "parse_reminder_value/1" do
    property "integers pass through unchanged" do
      check all(value <- integer(1..10_000)) do
        assert ReminderUtils.parse_reminder_value(value) == value
      end
    end

    property "string integers parse correctly" do
      check all(value <- integer(1..10_000)) do
        assert ReminderUtils.parse_reminder_value(to_string(value)) == value
      end
    end

    property "strings with trailing text still parse the leading integer" do
      check all(
              value <- integer(1..1000),
              suffix <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        assert ReminderUtils.parse_reminder_value("#{value} #{suffix}") == value
      end
    end

    property "non-positive integers default to 30" do
      check all(value <- integer(-1000..0)) do
        assert ReminderUtils.parse_reminder_value(value) == 30
      end
    end
  end

  describe "format_reminder_label/2" do
    property "singular units for value 1" do
      check all(unit <- member_of(["minutes", "hours", "days"])) do
        label = ReminderUtils.format_reminder_label(1, unit)
        singular = String.trim_trailing(unit, "s")
        assert label == "1 #{singular}"
      end
    end

    property "plural units for values > 1" do
      check all(
              value <- integer(2..1000),
              unit <- member_of(["minutes", "hours", "days"])
            ) do
        label = ReminderUtils.format_reminder_label(value, unit)
        assert label == "#{value} #{unit}"
      end
    end
  end
end
