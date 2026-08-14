defmodule Tymeslot.Availability.WeeklyAvailabilityQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Availability.WeeklyAvailabilityQueries

  describe "default business hours (user onboarding)" do
    test "creates sensible default schedule for new users" do
      schedule = insert(:availability_schedule)

      {:ok, _count} = WeeklyAvailabilityQueries.create_default_weekly_days(schedule.id)
      days = WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(schedule.id)

      # Should create 7 days
      assert length(days) == 7

      # Business week should be available with reasonable hours
      weekdays = Enum.filter(days, &(&1.day_of_week in 1..5))
      assert length(weekdays) == 5
      assert Enum.all?(weekdays, &(&1.is_available == true))
      assert Enum.all?(weekdays, &(&1.start_time == ~T[11:00:00]))
      assert Enum.all?(weekdays, &(&1.end_time == ~T[19:30:00]))

      # Weekends should be unavailable by default
      weekends = Enum.filter(days, &(&1.day_of_week in 6..7))
      assert length(weekends) == 2
      assert Enum.all?(weekends, &(&1.is_available == false))
    end

    test "returns error when pre-existing rows prevent full schedule creation" do
      schedule = insert(:availability_schedule)

      # Pre-seed one of the seven days so the bulk insert can only place 6 rows.
      # insert_all uses on_conflict: :nothing, so the conflict is silently skipped
      # and the returned count (6) triggers the :failed_to_create_schedule path.
      WeeklyAvailabilityQueries.create_weekly_availability(%{
        schedule_id: schedule.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      assert {:error, :failed_to_create_schedule} =
               WeeklyAvailabilityQueries.create_default_weekly_days(schedule.id)
    end
  end

  describe "availability validation (prevents booking issues)" do
    test "enforces valid day range to prevent system errors" do
      schedule = insert(:availability_schedule)

      invalid_day = %{
        schedule_id: schedule.id,
        # Invalid - should be 1-7
        day_of_week: 8,
        is_available: true
      }

      {:error, changeset} = WeeklyAvailabilityQueries.create_weekly_availability(invalid_day)
      refute changeset.valid?
      assert "must be between 1 (Monday) and 7 (Sunday)" in errors_on(changeset)[:day_of_week]
    end

    test "requires business hours when day is available" do
      schedule = insert(:availability_schedule)

      available_without_hours = %{
        schedule_id: schedule.id,
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
      schedule = insert(:availability_schedule)

      backwards_time_range = %{
        schedule_id: schedule.id,
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
