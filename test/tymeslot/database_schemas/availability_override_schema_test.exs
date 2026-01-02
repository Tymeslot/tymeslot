defmodule Tymeslot.DatabaseSchemas.AvailabilityOverrideSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.AvailabilityOverrideSchema

  describe "changeset/2 - override type validation" do
    test "accepts valid override types (unavailable, custom_hours, available)" do
      profile = insert(:profile)
      valid_types = ["unavailable", "custom_hours", "available"]

      for override_type <- valid_types do
        attrs = %{
          profile_id: profile.id,
          date: ~D[2025-01-15],
          override_type: override_type,
          start_time: if(override_type == "custom_hours", do: ~T[09:00:00], else: nil),
          end_time: if(override_type == "custom_hours", do: ~T[17:00:00], else: nil)
        }

        changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
        assert changeset.valid?, "Expected #{override_type} to be valid"
      end
    end

    test "rejects invalid override types" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "invalid_type"
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).override_type
    end

    test "requires override_type to be present" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15]
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).override_type
    end
  end

  describe "changeset/2 - date validation" do
    test "requires date to be present" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        override_type: "unavailable"
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).date
    end

    test "prevents duplicate overrides for the same profile and date" do
      profile = insert(:profile)
      date = ~D[2025-01-15]

      insert(:availability_override, profile: profile, date: date, override_type: "unavailable")

      {:error, changeset} =
        %AvailabilityOverrideSchema{}
        |> AvailabilityOverrideSchema.changeset(%{
          profile_id: profile.id,
          date: date,
          override_type: "available"
        })
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).profile_id
    end

    test "allows the same date for different profiles" do
      profile1 = insert(:profile)
      profile2 = insert(:profile)
      date = ~D[2025-01-15]

      insert(:availability_override, profile: profile1, date: date, override_type: "unavailable")

      {:ok, _override} =
        %AvailabilityOverrideSchema{}
        |> AvailabilityOverrideSchema.changeset(%{
          profile_id: profile2.id,
          date: date,
          override_type: "unavailable"
        })
        |> Repo.insert()
    end
  end

  describe "changeset/2 - time validation for custom_hours" do
    test "requires start_time and end_time when override_type is custom_hours" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "custom_hours"
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "are required for custom hours" in errors_on(changeset).start_time
      assert "are required for custom hours" in errors_on(changeset).end_time
    end

    test "ensures start_time is before end_time for custom_hours" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "custom_hours",
        start_time: ~T[17:00:00],
        end_time: ~T[09:00:00]
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "rejects equal start_time and end_time for custom_hours" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "custom_hours",
        start_time: ~T[09:00:00],
        end_time: ~T[09:00:00]
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "accepts valid time range for custom_hours" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "custom_hours",
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      assert changeset.valid?
    end
  end

  describe "changeset/2 - time validation for other override types" do
    test "does not require times for unavailable override" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "unavailable"
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      assert changeset.valid?
    end

    test "does not require times for available override" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "available"
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      assert changeset.valid?
    end
  end

  describe "changeset/2 - reason validation" do
    test "accepts reason within character limit" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "unavailable",
        reason: "Vacation day"
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      assert changeset.valid?
    end

    test "rejects reason longer than 100 characters" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "unavailable",
        reason: String.duplicate("a", 101)
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "must be 100 characters or less" in errors_on(changeset).reason
    end

    test "allows nil reason" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        date: ~D[2025-01-15],
        override_type: "unavailable",
        reason: nil
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      assert changeset.valid?
    end
  end

  describe "changeset/2 - profile_id validation" do
    test "requires profile_id to be present" do
      attrs = %{
        date: ~D[2025-01-15],
        override_type: "unavailable"
      }

      changeset = AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).profile_id
    end

    test "enforces foreign key constraint on profile_id" do
      attrs = %{
        profile_id: 999_999,
        date: ~D[2025-01-15],
        override_type: "unavailable"
      }

      {:error, changeset} =
        %AvailabilityOverrideSchema{}
        |> AvailabilityOverrideSchema.changeset(attrs)
        |> Repo.insert()

      assert "does not exist" in errors_on(changeset).profile_id
    end
  end
end
