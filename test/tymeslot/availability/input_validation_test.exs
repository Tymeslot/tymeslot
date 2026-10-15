defmodule Tymeslot.Availability.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @end_before_start "End time must be after start time. To run past midnight, pick an end time marked (+1)."

  @moduletag :availability

  alias Tymeslot.Availability.InputValidation

  describe "validate_day_hours/2" do
    test "accepts valid time range" do
      params = %{"start" => "09:00", "end" => "17:00"}
      assert {:ok, sanitized} = InputValidation.validate_day_hours(params)
      assert sanitized["start"] == "09:00"
      assert sanitized["end"] == "17:00"
    end

    test "accepts boundary times" do
      params = %{"start" => "00:00", "end" => "23:59"}
      assert {:ok, _sanitized} = InputValidation.validate_day_hours(params)
    end

    test "rejects invalid time format (missing leading zero)" do
      params = %{"start" => "9:00", "end" => "17:00"}
      assert {:error, errors} = InputValidation.validate_day_hours(params)
      assert Map.has_key?(errors, :start_time)
    end

    test "rejects invalid time format (no colon)" do
      params = %{"start" => "0900", "end" => "17:00"}
      assert {:error, errors} = InputValidation.validate_day_hours(params)
      assert Map.has_key?(errors, :start_time)
    end

    test "rejects end time equal to start time" do
      params = %{"start" => "09:00", "end" => "09:00"}
      assert {:error, errors} = InputValidation.validate_day_hours(params)
      assert errors[:start_time] == @end_before_start
      assert errors[:end_time] == @end_before_start
    end

    test "rejects end time before start time" do
      params = %{"start" => "17:00", "end" => "09:00"}
      assert {:error, errors} = InputValidation.validate_day_hours(params)
      assert errors[:start_time] == @end_before_start
      assert errors[:end_time] == @end_before_start
    end

    test "accepts hours that end the next day" do
      assert {:ok, %{"start" => "22:00", "end" => "02:00+1"}} =
               InputValidation.validate_day_hours(%{"start" => "22:00", "end" => "02:00+1"})
    end

    test "accepts a full 24 hours" do
      assert {:ok, _result} =
               InputValidation.validate_day_hours(%{"start" => "00:00", "end" => "00:00+1"})
    end

    test "points to the next-day ends when the end is before the start" do
      assert {:error, %{end_time: message}} =
               InputValidation.validate_day_hours(%{"start" => "18:00", "end" => "17:00"})

      assert message == @end_before_start
    end

    test "refuses next-day hours longer than 24 hours" do
      assert {:error, %{end_time: "Hours that end the next day can last at most 24 hours"}} =
               InputValidation.validate_day_hours(%{"start" => "09:00", "end" => "10:00+1"})
    end

    test "refuses a next-day suffix on the start" do
      assert {:error, %{start_time: _message}} =
               InputValidation.validate_day_hours(%{"start" => "22:00+1", "end" => "02:00+1"})
    end

    test "rejects non-string time values" do
      params = %{"start" => 900, "end" => "17:00"}
      assert {:error, _errors} = InputValidation.validate_day_hours(params)
    end
  end

  describe "validate_break_input/2" do
    test "accepts valid break with label" do
      params = %{"start" => "12:00", "end" => "13:00", "label" => "Lunch"}
      assert {:ok, sanitized} = InputValidation.validate_break_input(params)
      assert sanitized["start"] == "12:00"
      assert sanitized["end"] == "13:00"
      assert sanitized["label"] == "Lunch"
    end

    test "defaults label to 'Break' when nil" do
      params = %{"start" => "12:00", "end" => "13:00", "label" => nil}
      assert {:ok, sanitized} = InputValidation.validate_break_input(params)
      assert sanitized["label"] == "Break"
    end

    test "defaults label to 'Break' when empty string" do
      params = %{"start" => "12:00", "end" => "13:00", "label" => ""}
      assert {:ok, sanitized} = InputValidation.validate_break_input(params)
      assert sanitized["label"] == "Break"
    end

    test "defaults label to 'Break' when only whitespace" do
      params = %{"start" => "12:00", "end" => "13:00", "label" => "   "}
      assert {:ok, sanitized} = InputValidation.validate_break_input(params)
      assert sanitized["label"] == "Break"
    end

    test "rejects label exceeding 50 characters" do
      long_label = String.duplicate("a", 51)
      params = %{"start" => "12:00", "end" => "13:00", "label" => long_label}
      assert {:error, errors} = InputValidation.validate_break_input(params)
      assert Map.has_key?(errors, :label)
    end

    test "leaves a break's order to the day's hours" do
      # 23:30 to 00:30 is a valid break inside an overnight day, so only the
      # domain, which knows the day, can judge the order.
      assert {:ok, %{"start" => "23:30", "end" => "00:30"}} =
               InputValidation.validate_break_input(%{
                 "start" => "23:30",
                 "end" => "00:30",
                 "label" => "Tea"
               })
    end

    test "still rejects a malformed break time" do
      assert {:error, %{end_time: _message}} =
               InputValidation.validate_break_input(%{"start" => "12:00", "end" => "13:00+1"})
    end
  end

  describe "validate_quick_break_input/2" do
    test "accepts valid start time and duration" do
      params = %{"start" => "12:00", "duration" => "30"}
      assert {:ok, sanitized} = InputValidation.validate_quick_break_input(params)
      assert sanitized["start"] == "12:00"
      assert sanitized["duration"] == "30"
    end

    test "rejects zero duration" do
      params = %{"start" => "12:00", "duration" => "0"}
      assert {:error, errors} = InputValidation.validate_quick_break_input(params)
      assert Map.has_key?(errors, :duration)
    end

    test "rejects negative duration" do
      params = %{"start" => "12:00", "duration" => "-10"}
      assert {:error, errors} = InputValidation.validate_quick_break_input(params)
      assert Map.has_key?(errors, :duration)
    end

    test "rejects duration exceeding 480 minutes" do
      params = %{"start" => "12:00", "duration" => "481"}
      assert {:error, errors} = InputValidation.validate_quick_break_input(params)
      assert Map.has_key?(errors, :duration)
    end

    test "accepts maximum allowed duration (480 minutes)" do
      params = %{"start" => "12:00", "duration" => "480"}
      assert {:ok, sanitized} = InputValidation.validate_quick_break_input(params)
      assert sanitized["duration"] == "480"
    end

    test "rejects non-numeric duration" do
      params = %{"start" => "12:00", "duration" => "one hour"}
      assert {:error, errors} = InputValidation.validate_quick_break_input(params)
      assert Map.has_key?(errors, :duration)
    end

    test "rejects invalid start time format" do
      params = %{"start" => "noon", "duration" => "30"}
      assert {:error, errors} = InputValidation.validate_quick_break_input(params)
      assert Map.has_key?(errors, :start_time)
    end
  end

  describe "validate_day_selections/2" do
    test "accepts comma-separated valid day numbers" do
      assert {:ok, days} = InputValidation.validate_day_selections("1,3,5")
      assert Enum.sort(days) == [1, 3, 5]
    end

    test "accepts a single day" do
      assert {:ok, days} = InputValidation.validate_day_selections("2")
      assert days == [2]
    end

    test "deduplicates repeated days" do
      assert {:ok, days} = InputValidation.validate_day_selections("1,1,2")
      assert Enum.sort(days) == [1, 2]
    end

    test "filters out-of-range values (only 1-7 valid)" do
      assert {:ok, days} = InputValidation.validate_day_selections("0,1,7,8")
      assert Enum.sort(days) == [1, 7]
    end

    test "returns error when all values are out of range" do
      assert {:error, _reason} = InputValidation.validate_day_selections("0,8,9")
    end

    test "returns error for empty string" do
      assert {:error, _reason} = InputValidation.validate_day_selections("")
    end

    test "returns error for non-numeric content" do
      assert {:error, _reason} = InputValidation.validate_day_selections("mon,tue,wed")
    end
  end
end
