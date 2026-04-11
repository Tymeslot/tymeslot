defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.ValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Validation

  describe "validate_new_reminder/3" do
    test "returns ok with parsed reminder for valid input" do
      assert {:ok, %{value: 30, unit: "minutes"}} =
               Validation.validate_new_reminder([], "30", "minutes")
    end

    test "accepts all valid units" do
      assert {:ok, %{unit: "minutes"}} = Validation.validate_new_reminder([], "10", "minutes")
      assert {:ok, %{unit: "hours"}} = Validation.validate_new_reminder([], "2", "hours")
      assert {:ok, %{unit: "days"}} = Validation.validate_new_reminder([], "1", "days")
    end

    test "rejects nil value" do
      assert {:error, "Reminder value is required"} =
               Validation.validate_new_reminder([], nil, "minutes")
    end

    test "rejects empty string value" do
      assert {:error, "Reminder value is required"} =
               Validation.validate_new_reminder([], "", "minutes")
    end

    test "rejects non-positive value" do
      assert {:error, "Reminder value must be a positive number"} =
               Validation.validate_new_reminder([], "0", "minutes")
    end

    test "rejects negative value" do
      assert {:error, "Reminder value must be a positive number"} =
               Validation.validate_new_reminder([], "-5", "minutes")
    end

    test "rejects non-numeric value" do
      assert {:error, "Reminder value must be a positive number"} =
               Validation.validate_new_reminder([], "abc", "minutes")
    end

    test "rejects invalid unit" do
      assert {:error, "Select a valid reminder unit"} =
               Validation.validate_new_reminder([], "30", "weeks")
    end

    test "rejects duplicate reminder with same value and unit" do
      existing = [%{value: 30, unit: "minutes"}]

      assert {:error, "This reminder already exists"} =
               Validation.validate_new_reminder(existing, "30", "minutes")
    end

    test "rejects equivalent duplicate across units" do
      existing = [%{value: 1, unit: "hours"}]

      assert {:error, "This reminder already exists"} =
               Validation.validate_new_reminder(existing, "60", "minutes")
    end

    test "rejects when already at maximum of 3 reminders" do
      existing = [
        %{value: 10, unit: "minutes"},
        %{value: 30, unit: "minutes"},
        %{value: 1, unit: "hours"}
      ]

      assert {:error, "You can configure up to 3 reminders"} =
               Validation.validate_new_reminder(existing, "1", "days")
    end

    test "allows up to 3 reminders" do
      existing = [
        %{value: 10, unit: "minutes"},
        %{value: 30, unit: "minutes"}
      ]

      assert {:ok, %{value: 1, unit: "hours"}} =
               Validation.validate_new_reminder(existing, "1", "hours")
    end
  end

  describe "validate_and_update_field/5" do
    @metadata %{ip: "127.0.0.1", user_agent: "test", user_id: 1}

    test "validates name field and stores sanitised value on success" do
      {data, errors} =
        Validation.validate_and_update_field(
          "name",
          "Team Standup",
          @metadata,
          %{},
          %{}
        )

      assert data["name"] == "Team Standup"
      assert errors == %{}
    end

    test "validates name field and stores error on failure" do
      {data, errors} =
        Validation.validate_and_update_field(
          "name",
          "",
          @metadata,
          %{"name" => "old"},
          %{}
        )

      # Data unchanged on error
      assert data["name"] == "old"
      assert is_binary(errors[:name])
    end

    test "clears previous name error on successful validation" do
      {_, errors} =
        Validation.validate_and_update_field(
          "name",
          "Valid Name",
          @metadata,
          %{},
          %{name: "previous error"}
        )

      refute Map.has_key?(errors, :name)
    end

    test "validates duration field and stores sanitised value on success" do
      {data, errors} =
        Validation.validate_and_update_field(
          "duration",
          "30",
          @metadata,
          %{},
          %{}
        )

      assert data["duration"] == "30"
      assert errors == %{}
    end

    test "validates duration field and stores error on failure" do
      {data, errors} =
        Validation.validate_and_update_field(
          "duration",
          "3",
          @metadata,
          %{},
          %{}
        )

      # Duration below 5-minute minimum
      assert data == %{}
      assert is_binary(errors[:duration])
    end

    test "validates description field on success" do
      {data, errors} =
        Validation.validate_and_update_field(
          "description",
          "A short description",
          @metadata,
          %{},
          %{}
        )

      assert data["description"] == "A short description"
      assert errors == %{}
    end

    test "returns accumulator unchanged for unknown field" do
      acc_data = %{"name" => "Existing"}
      acc_errors = %{name: "some error"}

      {data, errors} =
        Validation.validate_and_update_field(
          "unknown_field",
          "value",
          @metadata,
          acc_data,
          acc_errors
        )

      assert data == acc_data
      assert errors == acc_errors
    end
  end
end
