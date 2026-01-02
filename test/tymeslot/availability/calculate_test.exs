defmodule Tymeslot.Availability.CalculateTest do
  @moduledoc """
  Tests for the availability calculation module.
  """

  use Tymeslot.DataCase, async: true

  alias Tymeslot.Availability.Calculate

  describe "validate_time_selection/3" do
    test "returns error when date is nil" do
      assert {:error, "Please select a date"} = Calculate.validate_time_selection(nil, "10:00 AM", [])
    end

    test "returns error when date is empty string" do
      assert {:error, "Please select a date"} = Calculate.validate_time_selection("", "10:00 AM", [])
    end

    test "returns error when time is nil" do
      assert {:error, "Please select a time"} =
               Calculate.validate_time_selection("2025-06-15", nil, [])
    end

    test "returns error when time is empty string" do
      assert {:error, "Please select a time"} =
               Calculate.validate_time_selection("2025-06-15", "", [])
    end

    test "returns ok when both date and time are provided with valid slots" do
      assert :ok = Calculate.validate_time_selection("2025-06-15", "10:00 AM", ["10:00 AM"])
    end

    test "returns ok with empty slots list when date and time are valid" do
      assert :ok = Calculate.validate_time_selection("2025-06-15", "10:00 AM", [])
    end

    test "handles edge case with non-list slots" do
      assert {:error, "Please select a date and time"} =
               Calculate.validate_time_selection("2025-06-15", "10:00 AM", :not_a_list)
    end
  end

  describe "time_slot_available?/3" do
    test "returns true for valid date, time, and slots list" do
      assert Calculate.time_slot_available?("2025-06-15", "10:00 AM", ["10:00 AM", "11:00 AM"])
    end

    test "returns true for empty slots list with valid strings" do
      assert Calculate.time_slot_available?("2025-06-15", "10:00 AM", [])
    end

    test "returns false for invalid date type" do
      refute Calculate.time_slot_available?(123, "10:00 AM", [])
    end

    test "returns false for invalid time type" do
      refute Calculate.time_slot_available?("2025-06-15", 123, [])
    end

    test "returns false for invalid slots type" do
      refute Calculate.time_slot_available?("2025-06-15", "10:00 AM", "not a list")
    end
  end

  describe "get_calendar_days/4" do
    test "returns 42 days for calendar display" do
      days = Calculate.get_calendar_days("America/New_York", 2025, 6, %{})

      assert length(days) == 42
    end

    test "each day has required keys" do
      days = Calculate.get_calendar_days("America/New_York", 2025, 6, %{})

      for day <- days do
        assert Map.has_key?(day, :date)
        assert Map.has_key?(day, :day)
        assert Map.has_key?(day, :available)
        assert Map.has_key?(day, :past)
        assert Map.has_key?(day, :today)
        assert Map.has_key?(day, :current_month)
      end
    end

    test "marks past dates as not available" do
      # Use a month in the past
      days = Calculate.get_calendar_days("America/New_York", 2020, 1, %{})

      # All days in January 2020 should be past and not available
      january_days = Enum.filter(days, &(&1.current_month))

      for day <- january_days do
        assert day.past == true
        assert day.available == false
      end
    end

    test "respects max_advance_booking_days config" do
      config = %{max_advance_booking_days: 7}

      # Get days for a future month
      future_date = Date.add(Date.utc_today(), 60)
      days = Calculate.get_calendar_days("America/New_York", future_date.year, future_date.month, config)

      # All days beyond 7 days should not be available
      available_days = Enum.filter(days, & &1.available)

      # Should have very few or no available days since we're looking at a month 60 days out
      # with only 7 days advance booking allowed
      assert Enum.all?(available_days, fn day ->
        {:ok, day_date} = Date.from_iso8601(day.date)
        Date.diff(day_date, Date.utc_today()) <= 7
      end)
    end

    test "handles UTC timezone" do
      days = Calculate.get_calendar_days("Etc/UTC", 2025, 6, %{})

      assert length(days) == 42
      assert is_list(days)
    end

    test "handles different timezones" do
      days_ny = Calculate.get_calendar_days("America/New_York", 2025, 6, %{})
      days_london = Calculate.get_calendar_days("Europe/London", 2025, 6, %{})
      days_tokyo = Calculate.get_calendar_days("Asia/Tokyo", 2025, 6, %{})

      # All should return 42 days
      assert length(days_ny) == 42
      assert length(days_london) == 42
      assert length(days_tokyo) == 42
    end

    test "marks today correctly" do
      today = Date.utc_today()
      days = Calculate.get_calendar_days("Etc/UTC", today.year, today.month, %{})

      today_entry = Enum.find(days, fn day ->
        day.date == Date.to_string(today)
      end)

      # There should be a today entry unless we're at a month boundary
      if today_entry do
        assert today_entry.today == true
        assert today_entry.past == false
      end
    end
  end

  describe "month_availability/6" do
    test "returns availability map for a month" do
      assert {:ok, availability_map} =
               Calculate.month_availability(
                 2025,
                 6,
                 "America/New_York",
                 "America/New_York",
                 [],
                 %{}
               )

      assert is_map(availability_map)
      # June has 30 days
      assert map_size(availability_map) == 30
    end

    test "marks all dates in the past as unavailable" do
      assert {:ok, availability_map} =
               Calculate.month_availability(
                 2020,
                 6,
                 "America/New_York",
                 "America/New_York",
                 [],
                 %{}
               )

      # All dates in June 2020 should be false (past)
      assert Enum.all?(availability_map, fn {_date, available} -> available == false end)
    end

    test "handles events parameter" do
      events = [
        %{
          start_time: DateTime.new!(~D[2025-06-15], ~T[10:00:00], "America/New_York"),
          end_time: DateTime.new!(~D[2025-06-15], ~T[11:00:00], "America/New_York")
        }
      ]

      assert {:ok, availability_map} =
               Calculate.month_availability(
                 2025,
                 6,
                 "America/New_York",
                 "America/New_York",
                 events,
                 %{}
               )

      assert is_map(availability_map)
    end

    test "respects max_advance_booking_days in config" do
      config = %{max_advance_booking_days: 7}

      # Check a month far in the future
      future_year = Date.utc_today().year + 1

      assert {:ok, availability_map} =
               Calculate.month_availability(
                 future_year,
                 6,
                 "America/New_York",
                 "America/New_York",
                 [],
                 config
               )

      # All dates should be unavailable since they're beyond 7 days
      assert Enum.all?(availability_map, fn {_date, available} -> available == false end)
    end
  end

  describe "available_slots/6" do
    test "returns empty list on weekend without profile settings" do
      today = Date.utc_today()

      days_until_saturday =
        case Date.day_of_week(today) do
          6 -> 0
          7 -> 6
          dow -> 6 - dow
        end

      saturday = Date.add(today, days_until_saturday)

      assert {:ok, slots} =
               Calculate.available_slots(
                 saturday,
                 30,
                 "Etc/UTC",
                 "Etc/UTC",
                 [],
                 %{}
               )

      assert slots == []
    end

    test "respects profile business hours when available" do
      profile = insert(:profile, timezone: "America/New_York")

      days_ahead =
        case Date.day_of_week(Date.utc_today()) do
          5 -> 3  # if Friday, jump to Monday to avoid weekend
          6 -> 2  # Saturday to Monday
          7 -> 1  # Sunday to Monday
          _ -> 1
        end

      future_weekday = Date.add(Date.utc_today(), days_ahead)

      insert(:weekly_availability,
        profile: profile,
        day_of_week: Date.day_of_week(future_weekday),
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        is_available: true
      )

      config = %{profile_id: profile.id}

      assert {:ok, slots} =
               Calculate.available_slots(
                 future_weekday,
                 30,
                 "America/New_York",
                 "America/New_York",
                 [],
                 config
               )

      assert "9:00 AM" in slots
      assert "9:30 AM" in slots
    end
  end
end
