defmodule Tymeslot.Availability.AvailabilityScheduleSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Validation.Constraints

  describe "scheduling policy defaults" do
    test "match the fallback the engine applies when no schedule resolves" do
      # A schedule saved without explicit policy values and a caller that could
      # resolve no schedule at all must land on the same rules. Were these to
      # drift, a half-configured account would be offered slots under one set of
      # numbers and have its bookings validated under another. The schema keeps
      # its literals so it carries no compile-time dependency on `Constraints`;
      # this test is what keeps the two honest.
      defaults = Constraints.scheduling_policy_defaults()
      schedule = %AvailabilityScheduleSchema{}

      assert schedule.buffer_minutes == defaults.buffer_minutes
      assert schedule.min_advance_hours == defaults.min_advance_hours
      assert schedule.advance_booking_days == defaults.advance_booking_days
    end

    test "a persisted schedule carries them when none are given" do
      profile = insert(:profile)

      {:ok, schedule} =
        %AvailabilityScheduleSchema{}
        |> AvailabilityScheduleSchema.changeset(%{profile_id: profile.id, name: "Bare"})
        |> Repo.insert()

      assert Map.take(schedule, Map.keys(Constraints.scheduling_policy_defaults())) ==
               Constraints.scheduling_policy_defaults()
    end
  end

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
