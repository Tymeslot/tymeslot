defmodule Tymeslot.Availability.AvailabilityScheduleSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability

  alias Ecto.Changeset
  alias Tymeslot.Availability.AvailabilityScheduleSchema

  describe "changeset/2" do
    test "requires profile_id and name" do
      changeset = AvailabilityScheduleSchema.changeset(%AvailabilityScheduleSchema{}, %{})

      errors = errors_on(changeset)
      assert errors.profile_id == ["can't be blank"]
      assert errors.name == ["can't be blank"]
    end

    test "rejects a whitespace-only name" do
      changeset =
        AvailabilityScheduleSchema.changeset(%AvailabilityScheduleSchema{}, %{
          profile_id: 1,
          name: "   "
        })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :name)
    end

    test "rejects policy values outside their allowed ranges" do
      changeset =
        AvailabilityScheduleSchema.changeset(%AvailabilityScheduleSchema{}, %{
          profile_id: 1,
          name: "Evenings",
          buffer_minutes: 999,
          min_advance_hours: -1,
          advance_booking_days: 0
        })

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :buffer_minutes)
      assert Map.has_key?(errors, :min_advance_hours)
      assert Map.has_key?(errors, :advance_booking_days)
    end

    test "accepts a valid schedule and trims the name" do
      changeset =
        AvailabilityScheduleSchema.changeset(%AvailabilityScheduleSchema{}, %{
          profile_id: 1,
          name: "  Evenings  "
        })

      assert changeset.valid?
      assert Changeset.get_change(changeset, :name) == "Evenings"
    end
  end

  describe "policy_changeset/2" do
    test "ignores name and default changes" do
      schedule = %AvailabilityScheduleSchema{name: "Working hours", is_default: true}

      changeset =
        AvailabilityScheduleSchema.policy_changeset(schedule, %{
          name: "Renamed",
          is_default: false,
          buffer_minutes: 30
        })

      assert changeset.valid?
      assert Changeset.get_change(changeset, :buffer_minutes) == 30
      assert Changeset.get_change(changeset, :name) == nil
      assert Changeset.get_change(changeset, :is_default) == nil
    end

    test "still enforces the policy ranges" do
      changeset =
        AvailabilityScheduleSchema.policy_changeset(%AvailabilityScheduleSchema{}, %{
          min_advance_hours: 10_000
        })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :min_advance_hours)
    end
  end
end
