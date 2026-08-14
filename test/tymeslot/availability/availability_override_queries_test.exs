defmodule Tymeslot.Availability.AvailabilityOverrideQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Availability.AvailabilityOverrideQueries

  describe "availability override queries" do
    test "get_override/1 returns the override by id" do
      override = insert(:availability_override)
      found = AvailabilityOverrideQueries.get_override(override.id)
      assert found.id == override.id
    end

    test "get_override_t/1 returns {:ok, override} when found" do
      override = insert(:availability_override)
      assert {:ok, found} = AvailabilityOverrideQueries.get_override_t(override.id)
      assert found.id == override.id
    end

    test "get_override_t/1 returns {:error, :not_found} when not found" do
      assert AvailabilityOverrideQueries.get_override_t(-1) == {:error, :not_found}
    end

    test "get_override_by_schedule_and_date/2 returns the override" do
      schedule = insert(:availability_schedule)
      date = Date.add(Date.utc_today(), 5)
      override = insert(:availability_override, schedule: schedule, date: date)

      found = AvailabilityOverrideQueries.get_override_by_schedule_and_date(schedule.id, date)
      assert found.id == override.id
    end

    test "get_override_by_schedule_and_date/2 is scoped to the schedule" do
      schedule = insert(:availability_schedule)
      other_schedule = insert(:availability_schedule)
      date = Date.add(Date.utc_today(), 5)
      insert(:availability_override, schedule: schedule, date: date)

      assert AvailabilityOverrideQueries.get_override_by_schedule_and_date(
               other_schedule.id,
               date
             ) == nil
    end

    test "get_overrides_by_schedule_and_date_range/3 returns overrides in range" do
      schedule = insert(:availability_schedule)
      today = Date.utc_today()
      insert(:availability_override, schedule: schedule, date: Date.add(today, 1))
      insert(:availability_override, schedule: schedule, date: Date.add(today, 3))
      insert(:availability_override, schedule: schedule, date: Date.add(today, 5))

      overrides =
        AvailabilityOverrideQueries.get_overrides_by_schedule_and_date_range(
          schedule.id,
          Date.add(today, 2),
          Date.add(today, 4)
        )

      assert length(overrides) == 1
    end

    test "get_overrides_by_schedule_and_date_range/3 excludes other schedules" do
      schedule = insert(:availability_schedule)
      today = Date.utc_today()
      insert(:availability_override, schedule: schedule, date: Date.add(today, 3))
      insert(:availability_override, date: Date.add(today, 3))

      overrides =
        AvailabilityOverrideQueries.get_overrides_by_schedule_and_date_range(
          schedule.id,
          Date.add(today, 1),
          Date.add(today, 5)
        )

      assert length(overrides) == 1
    end

    test "update_override/2 updates the override" do
      override = insert(:availability_override, reason: "Old Reason")

      {:ok, updated} =
        AvailabilityOverrideQueries.update_override(override, %{reason: "New Reason"})

      assert updated.reason == "New Reason"
    end

    test "delete_override/1 deletes the override" do
      override = insert(:availability_override)
      {:ok, _result} = AvailabilityOverrideQueries.delete_override(override)
      assert Repo.get(Tymeslot.Availability.AvailabilityOverrideSchema, override.id) == nil
    end
  end

  describe "availability override business rules" do
    test "prevents conflicting overrides for same date" do
      schedule = insert(:availability_schedule)
      tomorrow = Date.add(Date.utc_today(), 1)

      insert(:availability_override, schedule: schedule, date: tomorrow)

      conflicting_override = %{
        schedule_id: schedule.id,
        date: tomorrow,
        override_type: "unavailable"
      }

      result = AvailabilityOverrideQueries.create_override(conflicting_override)
      assert match?({:error, _reason}, result)
    end
  end

  describe "custom hours validation (business requirement)" do
    test "enforces time requirements for custom hours override" do
      schedule = insert(:availability_schedule)
      tomorrow = Date.add(Date.utc_today(), 1)

      incomplete_custom_hours = %{
        schedule_id: schedule.id,
        date: tomorrow,
        override_type: "custom_hours"
        # Missing required start_time and end_time
      }

      {:error, changeset} = AvailabilityOverrideQueries.create_override(incomplete_custom_hours)
      refute changeset.valid?
      assert "are required for custom hours" in errors_on(changeset)[:start_time]
    end
  end
end
