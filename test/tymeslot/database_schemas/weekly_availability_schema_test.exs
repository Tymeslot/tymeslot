defmodule Tymeslot.DatabaseSchemas.WeeklyAvailabilitySchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.WeeklyAvailabilitySchema

  describe "changeset/2 - day_of_week validation" do
    test "accepts valid day_of_week values (1-7)" do
      profile = insert(:profile)

      for day <- 1..7 do
        attrs = %{
          profile_id: profile.id,
          day_of_week: day,
          is_available: false
        }

        changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
        assert changeset.valid?, "Expected day_of_week #{day} to be valid"
      end
    end

    test "rejects day_of_week below 1" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 0,
        is_available: false
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "must be between 1 (Monday) and 7 (Sunday)" in errors_on(changeset).day_of_week
    end

    test "rejects day_of_week above 7" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 8,
        is_available: false
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "must be between 1 (Monday) and 7 (Sunday)" in errors_on(changeset).day_of_week
    end

    test "requires day_of_week to be present" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        is_available: false
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).day_of_week
    end
  end

  describe "changeset/2 - profile_id validation" do
    test "requires profile_id to be present" do
      attrs = %{
        day_of_week: 1,
        is_available: false
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).profile_id
    end

    test "enforces foreign key constraint on profile_id" do
      attrs = %{
        profile_id: 999_999,
        day_of_week: 1,
        is_available: false
      }

      {:error, changeset} =
        %WeeklyAvailabilitySchema{}
        |> WeeklyAvailabilitySchema.changeset(attrs)
        |> Repo.insert()

      assert "does not exist" in errors_on(changeset).profile_id
    end

    test "prevents duplicate day_of_week for same profile" do
      profile = insert(:profile)
      insert(:weekly_availability, profile: profile, day_of_week: 1)

      {:error, changeset} =
        %WeeklyAvailabilitySchema{}
        |> WeeklyAvailabilitySchema.changeset(%{
          profile_id: profile.id,
          day_of_week: 1,
          is_available: false
        })
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).profile_id
    end

    test "allows same day_of_week for different profiles" do
      profile1 = insert(:profile)
      profile2 = insert(:profile)

      insert(:weekly_availability, profile: profile1, day_of_week: 1)

      {:ok, availability} =
        %WeeklyAvailabilitySchema{}
        |> WeeklyAvailabilitySchema.changeset(%{
          profile_id: profile2.id,
          day_of_week: 1,
          is_available: false
        })
        |> Repo.insert()

      assert availability.profile_id == profile2.id
      assert availability.day_of_week == 1
    end
  end

  describe "changeset/2 - is_available defaults and time requirements" do
    test "defaults is_available to false" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
      assert get_field(changeset, :is_available) == false
    end

    test "does not require times when is_available is false" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: false
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
    end

    test "allows nil times when is_available is false" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: false,
        start_time: nil,
        end_time: nil
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
    end
  end

  describe "changeset/2 - time validation when is_available is true" do
    test "requires start_time when is_available is true" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        end_time: ~T[17:00:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "are required when day is available" in errors_on(changeset).start_time
    end

    test "requires end_time when is_available is true" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[09:00:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "are required when day is available" in errors_on(changeset).end_time
    end

    test "ensures end_time is after start_time when is_available is true" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[17:00:00],
        end_time: ~T[09:00:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "rejects equal start_time and end_time when is_available is true" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[09:00:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "accepts valid time range when is_available is true" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
    end

    test "rejects time range spanning into next day (e.g., night shift)" do
      profile = insert(:profile)

      # Note: This tests that the validation intentionally rejects overnight shifts
      # like 22:00-02:00. This structure requires shifts to be within a single day.
      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[22:00:00],
        end_time: ~T[02:00:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      # This will fail validation because end_time (02:00) is before start_time (22:00)
      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end
  end

  describe "changeset/2 - complete availability setup" do
    test "creates a complete weekday availability entry" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 2,
        is_available: true,
        start_time: ~T[08:30:00],
        end_time: ~T[18:30:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?

      assert get_field(changeset, :day_of_week) == 2
      assert get_field(changeset, :is_available) == true
      assert get_field(changeset, :start_time) == ~T[08:30:00]
      assert get_field(changeset, :end_time) == ~T[18:30:00]
    end

    test "creates a day marked as unavailable" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 7,
        is_available: false
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?

      assert get_field(changeset, :day_of_week) == 7
      assert get_field(changeset, :is_available) == false
    end

    test "allows updating availability from unavailable to available" do
      profile = insert(:profile)

      # Create unavailable day
      {:ok, availability} =
        %WeeklyAvailabilitySchema{}
        |> WeeklyAvailabilitySchema.changeset(%{
          profile_id: profile.id,
          day_of_week: 1,
          is_available: false
        })
        |> Repo.insert()

      # Update to available with times
      changeset =
        WeeklyAvailabilitySchema.changeset(availability, %{
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        })

      assert changeset.valid?
      assert get_field(changeset, :is_available) == true
    end

    test "allows updating availability from available to unavailable" do
      profile = insert(:profile)

      # Create available day
      {:ok, availability} =
        %WeeklyAvailabilitySchema{}
        |> WeeklyAvailabilitySchema.changeset(%{
          profile_id: profile.id,
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        })
        |> Repo.insert()

      # Update to unavailable
      changeset =
        WeeklyAvailabilitySchema.changeset(availability, %{
          is_available: false
        })

      assert changeset.valid?
      assert get_field(changeset, :is_available) == false
    end
  end

  describe "changeset/2 - edge cases" do
    test "accepts early morning hours" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[00:00:00],
        end_time: ~T[08:00:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
    end

    test "accepts late evening hours" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[18:00:00],
        end_time: ~T[23:59:59]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
    end

    test "accepts full day availability" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[00:00:00],
        end_time: ~T[23:59:59]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
    end

    test "accepts short availability windows" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[12:00:00],
        end_time: ~T[12:30:00]
      }

      changeset = WeeklyAvailabilitySchema.changeset(%WeeklyAvailabilitySchema{}, attrs)
      assert changeset.valid?
    end
  end
end
