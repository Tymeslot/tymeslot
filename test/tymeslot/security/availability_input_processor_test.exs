defmodule Tymeslot.Security.AvailabilityInputProcessorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.AvailabilityInputProcessor

  describe "validate_day_hours/2" do
  @moduletag :security
    test "accepts valid day hours" do
      params = %{"start" => "09:00", "end" => "17:00"}
      assert {:ok, sanitized} = AvailabilityInputProcessor.validate_day_hours(params)
      assert sanitized["start"] == "09:00"
      assert sanitized["end"] == "17:00"
    end

    test "rejects invalid time format" do
      params = %{"start" => "9:00", "end" => "17:00"}
      assert {:error, errors} = AvailabilityInputProcessor.validate_day_hours(params)
      assert errors[:start_time] == "Invalid time value"
    end

    test "rejects end time before start time" do
      params = %{"start" => "17:00", "end" => "09:00"}
      assert {:error, errors} = AvailabilityInputProcessor.validate_day_hours(params)
      assert errors[:time_range] == "End time must be after start time"
    end
  end

  describe "validate_break_input/2" do
    test "accepts valid break input" do
      params = %{"start" => "12:00", "end" => "13:00", "label" => "Lunch"}
      assert {:ok, sanitized} = AvailabilityInputProcessor.validate_break_input(params)
      assert sanitized["start"] == "12:00"
      assert sanitized["end"] == "13:00"
      assert sanitized["label"] == "Lunch"
    end

    test "uses default label if empty" do
      params = %{"start" => "12:00", "end" => "13:00", "label" => ""}
      assert {:ok, sanitized} = AvailabilityInputProcessor.validate_break_input(params)
      assert sanitized["label"] == "Break"
    end

    test "rejects too long label" do
      params = %{"start" => "12:00", "end" => "13:00", "label" => String.duplicate("a", 51)}
      assert {:error, errors} = AvailabilityInputProcessor.validate_break_input(params)
      assert errors[:label] == "Break label must be 50 characters or less"
    end
  end

  describe "validate_quick_break_input/2" do
    test "accepts valid quick break" do
      params = %{"start" => "14:00", "duration" => "15"}
      assert {:ok, sanitized} = AvailabilityInputProcessor.validate_quick_break_input(params)
      assert sanitized["start"] == "14:00"
      assert sanitized["duration"] == "15"
    end

    test "rejects negative duration" do
      params = %{"start" => "14:00", "duration" => "0"}
      assert {:error, errors} = AvailabilityInputProcessor.validate_quick_break_input(params)
      assert errors[:duration] == "Duration must be greater than 0 minutes"
    end

    test "rejects duration over 8 hours" do
      params = %{"start" => "14:00", "duration" => "481"}
      assert {:error, errors} = AvailabilityInputProcessor.validate_quick_break_input(params)
      assert errors[:duration] == "Duration cannot exceed 8 hours (480 minutes)"
    end
  end

  describe "validate_day_selections/2" do
    test "accepts valid day selections" do
      assert {:ok, [1, 2, 3]} = AvailabilityInputProcessor.validate_day_selections("1,2,3")
      assert {:ok, [1, 5]} = AvailabilityInputProcessor.validate_day_selections(" 1, 5 ")
    end

    test "rejects invalid day numbers" do
      assert {:ok, [1, 2]} = AvailabilityInputProcessor.validate_day_selections("1,2,8")
    end

    test "rejects empty selections" do
      assert {:error, "No valid days selected"} =
               AvailabilityInputProcessor.validate_day_selections("")
    end

    test "rejects out of range days" do
      assert {:error, "No valid days selected"} =
               AvailabilityInputProcessor.validate_day_selections("8,9")
    end

    test "rejects invalid format" do
      assert {:error, "Invalid day selection format"} =
               AvailabilityInputProcessor.validate_day_selections("one,two")
    end
  end
end
