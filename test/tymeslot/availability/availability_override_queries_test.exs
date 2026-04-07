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

    test "get_override_by_profile_and_date/2 returns the override" do
      profile = insert(:profile)
      date = Date.add(Date.utc_today(), 5)
      override = insert(:availability_override, profile: profile, date: date)

      found = AvailabilityOverrideQueries.get_override_by_profile_and_date(profile.id, date)
      assert found.id == override.id
    end

    test "get_override_by_profile_and_date_t/2 returns {:ok, override} when found" do
      profile = insert(:profile)
      date = Date.add(Date.utc_today(), 5)
      override = insert(:availability_override, profile: profile, date: date)

      assert {:ok, found} =
               AvailabilityOverrideQueries.get_override_by_profile_and_date_t(profile.id, date)

      assert found.id == override.id
    end

    test "get_overrides_by_profile/1 returns all overrides for profile" do
      profile = insert(:profile)
      insert(:availability_override, profile: profile, date: Date.add(Date.utc_today(), 1))
      insert(:availability_override, profile: profile, date: Date.add(Date.utc_today(), 2))
      insert(:availability_override, profile: insert(:profile))

      overrides = AvailabilityOverrideQueries.get_overrides_by_profile(profile.id)
      assert length(overrides) == 2
    end

    test "get_overrides_by_profile_and_date_range/3 returns overrides in range" do
      profile = insert(:profile)
      today = Date.utc_today()
      insert(:availability_override, profile: profile, date: Date.add(today, 1))
      insert(:availability_override, profile: profile, date: Date.add(today, 3))
      insert(:availability_override, profile: profile, date: Date.add(today, 5))

      overrides =
        AvailabilityOverrideQueries.get_overrides_by_profile_and_date_range(
          profile.id,
          Date.add(today, 2),
          Date.add(today, 4)
        )

      assert length(overrides) == 1
    end

    test "get_overrides_by_profile_and_type/2 returns overrides of specific type" do
      profile = insert(:profile)

      insert(:availability_override,
        profile: profile,
        override_type: "unavailable",
        date: Date.add(Date.utc_today(), 1)
      )

      insert(:availability_override,
        profile: profile,
        override_type: "custom_hours",
        date: Date.add(Date.utc_today(), 2),
        start_time: ~T[08:00:00],
        end_time: ~T[12:00:00]
      )

      overrides =
        AvailabilityOverrideQueries.get_overrides_by_profile_and_type(profile.id, "unavailable")

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

    test "delete_overrides_by_profile/1 deletes all for profile" do
      profile = insert(:profile)
      insert(:availability_override, profile: profile, date: Date.add(Date.utc_today(), 1))
      insert(:availability_override, profile: profile, date: Date.add(Date.utc_today(), 2))

      {count, _value} = AvailabilityOverrideQueries.delete_overrides_by_profile(profile.id)
      assert count == 2
      assert AvailabilityOverrideQueries.get_overrides_by_profile(profile.id) == []
    end

    test "delete_overrides_before_date/2 deletes old overrides" do
      profile = insert(:profile)
      today = Date.utc_today()
      insert(:availability_override, profile: profile, date: Date.add(today, -5))
      insert(:availability_override, profile: profile, date: Date.add(today, -2))
      insert(:availability_override, profile: profile, date: Date.add(today, 2))

      {count, _value} =
        AvailabilityOverrideQueries.delete_overrides_before_date(profile.id, today)

      assert count == 2
      assert length(AvailabilityOverrideQueries.get_overrides_by_profile(profile.id)) == 1
    end
  end

  describe "availability override business rules" do
    test "prevents conflicting overrides for same date" do
      profile = insert(:profile)
      tomorrow = Date.add(Date.utc_today(), 1)

      insert(:availability_override, profile: profile, date: tomorrow)

      conflicting_override = %{
        profile_id: profile.id,
        date: tomorrow,
        override_type: "unavailable"
      }

      result = AvailabilityOverrideQueries.create_override(conflicting_override)
      assert match?({:error, _reason}, result)
    end
  end

  describe "custom hours validation (business requirement)" do
    test "enforces time requirements for custom hours override" do
      profile = insert(:profile)
      tomorrow = Date.add(Date.utc_today(), 1)

      incomplete_custom_hours = %{
        profile_id: profile.id,
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
