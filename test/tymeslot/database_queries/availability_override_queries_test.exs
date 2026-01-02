defmodule Tymeslot.DatabaseQueries.AvailabilityOverrideQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.AvailabilityOverrideQueries

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
      assert match?({:error, _}, result)
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
