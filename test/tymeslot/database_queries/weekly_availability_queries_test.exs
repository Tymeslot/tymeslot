defmodule Tymeslot.DatabaseQueries.WeeklyAvailabilityQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.WeeklyAvailabilityQueries

  describe "default business hours (user onboarding)" do
    test "creates sensible default schedule for new users" do
      profile = insert(:profile)

      {:ok, _} = WeeklyAvailabilityQueries.create_default_weekly_schedule(profile.id)
      schedule = WeeklyAvailabilityQueries.get_weekly_availability_by_profile(profile.id)

      # Should create 7 days
      assert length(schedule) == 7

      # Business week should be available with reasonable hours
      weekdays = Enum.filter(schedule, &(&1.day_of_week in 1..5))
      assert length(weekdays) == 5
      assert Enum.all?(weekdays, &(&1.is_available == true))
      assert Enum.all?(weekdays, &(&1.start_time == ~T[11:00:00]))
      assert Enum.all?(weekdays, &(&1.end_time == ~T[19:30:00]))

      # Weekends should be unavailable by default
      weekends = Enum.filter(schedule, &(&1.day_of_week in 6..7))
      assert length(weekends) == 2
      assert Enum.all?(weekends, &(&1.is_available == false))
    end
  end

  describe "availability validation (prevents booking issues)" do
    test "enforces valid day range to prevent system errors" do
      profile = insert(:profile)

      invalid_day = %{
        profile_id: profile.id,
        # Invalid - should be 1-7
        day_of_week: 8,
        is_available: true
      }

      {:error, changeset} = WeeklyAvailabilityQueries.create_weekly_availability(invalid_day)
      refute changeset.valid?
      assert "must be between 1 (Monday) and 7 (Sunday)" in errors_on(changeset)[:day_of_week]
    end

    test "requires business hours when day is available" do
      profile = insert(:profile)

      available_without_hours = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true
        # Missing required start_time and end_time
      }

      {:error, changeset} =
        WeeklyAvailabilityQueries.create_weekly_availability(available_without_hours)

      refute changeset.valid?
      assert "are required when day is available" in errors_on(changeset)[:start_time]
      assert "are required when day is available" in errors_on(changeset)[:end_time]
    end

    test "prevents invalid time ranges that would break booking" do
      profile = insert(:profile)

      backwards_time_range = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[17:00:00],
        # Invalid - before start_time
        end_time: ~T[09:00:00]
      }

      {:error, changeset} =
        WeeklyAvailabilityQueries.create_weekly_availability(backwards_time_range)

      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset)[:end_time]
    end
  end
end
