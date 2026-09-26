defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.ValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Validation

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
      assert errors[:name] == "Meeting name is required"
    end

    test "clears previous name error on successful validation" do
      {_data, errors} =
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
      assert errors[:duration] == "Duration must be at least 5 minutes"
    end

    test "validates slot_interval field and stores sanitised value on success" do
      {data, errors} =
        Validation.validate_and_update_field(
          "slot_interval",
          "15",
          @metadata,
          %{},
          %{}
        )

      assert data["slot_interval"] == "15"
      assert errors == %{}
    end

    test "validates slot_interval field and accepts a blank value" do
      {data, errors} =
        Validation.validate_and_update_field(
          "slot_interval",
          "",
          @metadata,
          %{},
          %{}
        )

      assert data["slot_interval"] == ""
      assert errors == %{}
    end

    test "validates slot_interval field and stores error on failure" do
      {data, errors} =
        Validation.validate_and_update_field(
          "slot_interval",
          "4",
          @metadata,
          %{},
          %{}
        )

      assert data == %{}
      assert errors[:slot_interval] == "Slot interval must be at least 5 minutes"
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
