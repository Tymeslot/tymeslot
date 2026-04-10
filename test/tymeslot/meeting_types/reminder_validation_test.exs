defmodule Tymeslot.MeetingTypes.ReminderValidationTest do
  @moduledoc """
  Unit tests for ReminderValidation — parsing, normalisation, and policy enforcement.
  """
  use ExUnit.Case, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.ReminderValidation

  # ---------------------------------------------------------------------------
  # parse_and_normalize_reminders/1
  # ---------------------------------------------------------------------------

  describe "parse_and_normalize_reminders/1 — JSON string" do
    test "parses a valid JSON array of reminders" do
      json = Jason.encode!([%{"value" => 30, "unit" => "minutes"}])
      assert {:ok, [%{value: 30, unit: "minutes"}]} = ReminderValidation.parse_and_normalize_reminders(json)
    end

    test "parses a JSON array with multiple valid reminders" do
      json = Jason.encode!([
        %{"value" => 15, "unit" => "minutes"},
        %{"value" => 1, "unit" => "hours"}
      ])

      assert {:ok, reminders} = ReminderValidation.parse_and_normalize_reminders(json)
      assert length(reminders) == 2
    end

    test "returns error for malformed JSON string" do
      assert {:error, _message} = ReminderValidation.parse_and_normalize_reminders("{not json}")
    end

    test "returns error for JSON string that is not an array or map" do
      json = Jason.encode!("just a string")
      assert {:error, _message} = ReminderValidation.parse_and_normalize_reminders(json)
    end
  end

  describe "parse_and_normalize_reminders/1 — map keyed by index" do
    test "normalises Phoenix form params map into a list" do
      params = %{
        "0" => %{"value" => "30", "unit" => "minutes"},
        "1" => %{"value" => "1", "unit" => "hours"}
      }

      assert {:ok, reminders} = ReminderValidation.parse_and_normalize_reminders(params)
      assert length(reminders) == 2
      assert Enum.all?(reminders, &match?(%{value: _, unit: _}, &1))
    end

    test "normalises a single-entry index map" do
      params = %{"0" => %{"value" => "15", "unit" => "minutes"}}
      assert {:ok, [%{value: 15, unit: "minutes"}]} = ReminderValidation.parse_and_normalize_reminders(params)
    end

    test "returns error when a reminder in the map has an invalid unit" do
      params = %{"0" => %{"value" => "30", "unit" => "fortnights"}}
      assert {:error, _message} = ReminderValidation.parse_and_normalize_reminders(params)
    end
  end

  describe "parse_and_normalize_reminders/1 — list" do
    test "normalises a list of string-keyed reminder maps" do
      reminders = [%{"value" => 30, "unit" => "minutes"}]
      assert {:ok, [%{value: 30, unit: "minutes"}]} = ReminderValidation.parse_and_normalize_reminders(reminders)
    end

    test "returns ok for an empty list" do
      assert {:ok, []} = ReminderValidation.parse_and_normalize_reminders([])
    end

    test "returns error when any reminder in the list is invalid" do
      reminders = [
        %{"value" => 30, "unit" => "minutes"},
        %{"value" => -1, "unit" => "hours"}
      ]

      assert {:error, _message} = ReminderValidation.parse_and_normalize_reminders(reminders)
    end
  end

  describe "parse_and_normalize_reminders/1 — unsupported types" do
    test "returns error for an integer" do
      assert {:error, _message} = ReminderValidation.parse_and_normalize_reminders(42)
    end

    test "returns error for nil" do
      assert {:error, _message} = ReminderValidation.parse_and_normalize_reminders(nil)
    end

    test "returns error for an atom" do
      assert {:error, _message} = ReminderValidation.parse_and_normalize_reminders(:reminders)
    end
  end

  # ---------------------------------------------------------------------------
  # validate_reminders_policy/1
  # ---------------------------------------------------------------------------

  describe "validate_reminders_policy/1" do
    test "accepts an empty list" do
      assert :ok = ReminderValidation.validate_reminders_policy([])
    end

    test "accepts up to 3 reminders" do
      reminders = [
        %{value: 10, unit: "minutes"},
        %{value: 30, unit: "minutes"},
        %{value: 1, unit: "hours"}
      ]

      assert :ok = ReminderValidation.validate_reminders_policy(reminders)
    end

    test "rejects more than 3 reminders" do
      reminders = [
        %{value: 10, unit: "minutes"},
        %{value: 20, unit: "minutes"},
        %{value: 30, unit: "minutes"},
        %{value: 40, unit: "minutes"}
      ]

      assert {:error, message} = ReminderValidation.validate_reminders_policy(reminders)
      assert message =~ "3"
    end

    test "rejects duplicate reminders" do
      reminders = [
        %{value: 30, unit: "minutes"},
        %{value: 30, unit: "minutes"}
      ]

      assert {:error, message} = ReminderValidation.validate_reminders_policy(reminders)
      assert message =~ "unique"
    end

    test "rejects reminders that are semantically duplicate across units" do
      reminders = [
        %{value: 60, unit: "minutes"},
        %{value: 1, unit: "hours"}
      ]

      assert {:error, _message} = ReminderValidation.validate_reminders_policy(reminders)
    end

    test "rejects a reminder exceeding one year" do
      reminders = [%{value: 366, unit: "days"}]

      assert {:error, message} = ReminderValidation.validate_reminders_policy(reminders)
      assert message =~ "1 year"
    end

    test "accepts a reminder of exactly one year" do
      reminders = [%{value: 365, unit: "days"}]
      assert :ok = ReminderValidation.validate_reminders_policy(reminders)
    end
  end

  # ---------------------------------------------------------------------------
  # validate_reminder_config/2
  # ---------------------------------------------------------------------------

  describe "validate_reminder_config/2" do
    test "returns empty list for nil" do
      assert {:ok, []} = ReminderValidation.validate_reminder_config(nil, %{})
    end

    test "returns empty list for empty string" do
      assert {:ok, []} = ReminderValidation.validate_reminder_config("", %{})
    end

    test "accepts a valid JSON string" do
      json = Jason.encode!([%{"value" => 30, "unit" => "minutes"}])
      assert {:ok, [%{value: 30, unit: "minutes"}]} = ReminderValidation.validate_reminder_config(json, %{})
    end

    test "accepts a valid list of reminder maps" do
      reminders = [%{"value" => 30, "unit" => "minutes"}]
      assert {:ok, [%{value: 30, unit: "minutes"}]} = ReminderValidation.validate_reminder_config(reminders, %{})
    end

    test "accepts a Phoenix form index map" do
      params = %{"0" => %{"value" => "15", "unit" => "minutes"}}
      assert {:ok, [%{value: 15, unit: "minutes"}]} = ReminderValidation.validate_reminder_config(params, %{})
    end

    test "returns a reminder_config error key for malformed JSON" do
      assert {:error, %{reminder_config: _message}} =
               ReminderValidation.validate_reminder_config("{bad json}", %{})
    end

    test "returns a reminder_config error key when policy is violated" do
      reminders = [
        %{"value" => "30", "unit" => "minutes"},
        %{"value" => "30", "unit" => "minutes"}
      ]

      assert {:error, %{reminder_config: _message}} =
               ReminderValidation.validate_reminder_config(reminders, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # reminder_exceeds_max?/1
  # ---------------------------------------------------------------------------

  describe "reminder_exceeds_max?/1" do
    test "returns false for a short reminder" do
      refute ReminderValidation.reminder_exceeds_max?(%{value: 30, unit: "minutes"})
    end

    test "returns false for exactly one year (365 days)" do
      refute ReminderValidation.reminder_exceeds_max?(%{value: 365, unit: "days"})
    end

    test "returns true for a reminder exceeding one year" do
      assert ReminderValidation.reminder_exceeds_max?(%{value: 366, unit: "days"})
    end
  end
end
