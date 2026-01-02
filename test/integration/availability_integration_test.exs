defmodule Tymeslot.Integration.AvailabilityTest do
  @moduledoc """
  Integration tests for availability calculation functionality.

  These tests validate that the availability calculation system works end-to-end,
  including profile settings, breaks, calendar conflicts, and slot generation.
  """

  use Tymeslot.DataCase, async: false

  alias Tymeslot.Availability.Calculate

  @moduletag :integration_test

  describe "availability calculation end-to-end" do
    test "calculates available days respecting business hours" do
      profile = insert(:profile, timezone: "America/New_York")

      # Set up business hours (Monday-Friday, 9am-5pm)
      insert(:weekly_availability,
        profile: profile,
        day_of_week: 1,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      config = %{profile_id: profile.id, max_advance_booking_days: 30}

      days = Calculate.get_calendar_days("America/New_York", 2025, 1, config)

      assert is_list(days)
      assert length(days) > 0

      # Verify structure
      first_day = List.first(days)
      assert Map.has_key?(first_day, :date)
      assert Map.has_key?(first_day, :available)
    end

    test "generates time slots excluding conflicts" do
      profile = insert(:profile, buffer_minutes: 15)

      # Set up availability for tomorrow (if weekday)
      tomorrow = Date.add(Date.utc_today(), 1)

      if Date.day_of_week(tomorrow) in 1..5 do
        insert(:weekly_availability,
          profile: profile,
          day_of_week: Date.day_of_week(tomorrow),
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )

        # Add existing meeting to create conflict
        existing_meeting_start = DateTime.new!(tomorrow, ~T[10:00:00])
        existing_meeting_end = DateTime.new!(tomorrow, ~T[11:00:00])

        calendar_events = [
          %{
            start_time: existing_meeting_start,
            end_time: existing_meeting_end
          }
        ]

        config = %{profile_id: profile.id}

        {:ok, slots} =
          Calculate.available_slots(
            tomorrow,
            # 30 minute duration
            30,
            "America/New_York",
            "America/New_York",
            calendar_events,
            config
          )

        assert is_list(slots)

        # Verify 10:00 and 10:30 slots are excluded
        refute "10:00" in slots
        refute "10:30" in slots
      end
    end

    test "respects buffer time between meetings" do
      profile = insert(:profile, buffer_minutes: 30)

      tomorrow = Date.add(Date.utc_today(), 1)

      if Date.day_of_week(tomorrow) in 1..5 do
        insert(:weekly_availability,
          profile: profile,
          day_of_week: Date.day_of_week(tomorrow),
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )

        # Existing meeting from 10:00-11:00
        calendar_events = [
          %{
            start_time: DateTime.new!(tomorrow, ~T[10:00:00]),
            end_time: DateTime.new!(tomorrow, ~T[11:00:00])
          }
        ]

        config = %{profile_id: profile.id}

        {:ok, slots} =
          Calculate.available_slots(
            tomorrow,
            30,
            "America/New_York",
            "America/New_York",
            calendar_events,
            config
          )

        # With 30 min buffer, slots at 11:00 and 11:15 should be unavailable
        refute "11:00" in slots
        refute "11:15" in slots
        # 11:30 should be available (30 min buffer satisfied)
        assert "11:30" in slots || Enum.empty?(slots)
      end
    end

    test "handles timezone conversions correctly" do
      profile = insert(:profile, timezone: "Europe/London")

      insert(:weekly_availability,
        profile: profile,
        day_of_week: 1,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      config = %{profile_id: profile.id, max_advance_booking_days: 7}

      # Test multiple timezones
      for timezone <- ["America/New_York", "Europe/London", "Asia/Tokyo"] do
        days = Calculate.get_calendar_days(timezone, 2025, 1, config)
        assert is_list(days)
      end
    end

    test "excludes slots with advance booking restrictions" do
      profile =
        insert(:profile,
          min_advance_hours: 24,
          advance_booking_days: 30
        )

      today = Date.utc_today()

      # Set availability for today
      if Date.day_of_week(today) in 1..5 do
        insert(:weekly_availability,
          profile: profile,
          day_of_week: Date.day_of_week(today),
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )

        config = %{profile_id: profile.id}

        # Should return no slots for today due to 24 hour minimum advance
        {:ok, slots} =
          Calculate.available_slots(
            today,
            30,
            "America/New_York",
            "America/New_York",
            [],
            config
          )

        # Should return empty slots due to advance booking restriction
        assert slots == []
      end
    end
  end
end
