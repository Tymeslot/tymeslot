defmodule Tymeslot.DatabaseSchemas.AvailabilityBreakSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.AvailabilityBreakSchema

  describe "business rule validations" do
    test "break end time must be after start time" do
      weekly_availability = insert(:weekly_availability)

      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[14:00:00],
        # End before start - invalid
        end_time: ~T[13:00:00]
      }

      changeset = AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs)

      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "break must be within weekly availability work hours" do
      weekly_availability = insert(:weekly_availability, start_time: ~T[09:00:00], end_time: ~T[17:00:00])

      # Case 1: Break starts before work hours
      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[08:30:00],
        end_time: ~T[09:30:00]
      }
      changeset = AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs)
      refute changeset.valid?
      assert "must be within work hours" in errors_on(changeset).start_time

      # Case 2: Break ends after work hours
      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[16:30:00],
        end_time: ~T[17:30:00]
      }
      changeset = AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs)
      refute changeset.valid?
      assert "must be within work hours" in errors_on(changeset).end_time

      # Case 3: Valid break within work hours
      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[12:00:00],
        end_time: ~T[13:00:00]
      }
      changeset = AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs)
      assert changeset.valid?
    end
  end
end
