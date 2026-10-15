defmodule TymeslotWeb.Components.Shared.ReminderPickerTest do
  @moduledoc """
  Covers the shared reminder picker's validation: what it accepts as a
  reminder, and which of the policy's rules it words for the surface adding
  one.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias TymeslotWeb.Components.Shared.ReminderPicker

  describe "validate_new_reminder/3" do
    test "returns ok with parsed reminder for valid input" do
      assert {:ok, %{value: 30, unit: "minutes"}} =
               ReminderPicker.validate_new_reminder([], "30", "minutes")
    end

    test "accepts all valid units" do
      assert {:ok, %{unit: "minutes"}} = ReminderPicker.validate_new_reminder([], "10", "minutes")
      assert {:ok, %{unit: "hours"}} = ReminderPicker.validate_new_reminder([], "2", "hours")
      assert {:ok, %{unit: "days"}} = ReminderPicker.validate_new_reminder([], "1", "days")
    end

    test "rejects nil value" do
      assert {:error, "Reminder value is required"} =
               ReminderPicker.validate_new_reminder([], nil, "minutes")
    end

    test "rejects empty string value" do
      assert {:error, "Reminder value is required"} =
               ReminderPicker.validate_new_reminder([], "", "minutes")
    end

    test "rejects non-positive value" do
      assert {:error, "Reminder value must be a positive number"} =
               ReminderPicker.validate_new_reminder([], "0", "minutes")
    end

    test "rejects negative value" do
      assert {:error, "Reminder value must be a positive number"} =
               ReminderPicker.validate_new_reminder([], "-5", "minutes")
    end

    test "rejects non-numeric value" do
      assert {:error, "Reminder value must be a positive number"} =
               ReminderPicker.validate_new_reminder([], "abc", "minutes")
    end

    test "rejects invalid unit" do
      assert {:error, "Select a valid reminder unit"} =
               ReminderPicker.validate_new_reminder([], "30", "weeks")
    end

    test "rejects duplicate reminder with same value and unit" do
      existing = [%{value: 30, unit: "minutes"}]

      assert {:error, "This reminder already exists"} =
               ReminderPicker.validate_new_reminder(existing, "30", "minutes")
    end

    test "rejects equivalent duplicate across units" do
      existing = [%{value: 1, unit: "hours"}]

      assert {:error, "This reminder already exists"} =
               ReminderPicker.validate_new_reminder(existing, "60", "minutes")
    end

    test "rejects when already at maximum of 3 reminders" do
      existing = [
        %{value: 10, unit: "minutes"},
        %{value: 30, unit: "minutes"},
        %{value: 1, unit: "hours"}
      ]

      assert {:error, "You can configure up to 3 reminders"} =
               ReminderPicker.validate_new_reminder(existing, "1", "days")
    end

    test "rejects a reminder more than one year in advance" do
      assert {:error, "Reminders cannot be set for more than 1 year in advance"} =
               ReminderPicker.validate_new_reminder([], "366", "days")
    end

    test "adds beside a reminder over a year saved before the limit existed" do
      assert {:ok, %{value: 1, unit: "hours"}} =
               ReminderPicker.validate_new_reminder([%{value: 400, unit: "days"}], "1", "hours")
    end

    test "accepts a reminder exactly one year in advance" do
      assert {:ok, %{value: 365, unit: "days"}} =
               ReminderPicker.validate_new_reminder([], "365", "days")
    end

    test "allows up to 3 reminders" do
      existing = [
        %{value: 10, unit: "minutes"},
        %{value: 30, unit: "minutes"}
      ]

      assert {:ok, %{value: 1, unit: "hours"}} =
               ReminderPicker.validate_new_reminder(existing, "1", "hours")
    end
  end
end
