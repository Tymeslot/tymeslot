defmodule Tymeslot.Availability.AvailabilityBreakSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.Availability.AvailabilityBreakSchema

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
      weekly_availability =
        insert(:weekly_availability, start_time: ~T[09:00:00], end_time: ~T[17:00:00])

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

    test "a break outside the hours at both ends is reported at both ends" do
      weekly_availability =
        insert(:weekly_availability, start_time: ~T[09:00:00], end_time: ~T[17:00:00])

      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[08:00:00],
        end_time: ~T[18:00:00]
      }

      errors = errors_on(AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs))

      assert errors.start_time == ["must be within work hours"]
      assert errors.end_time == ["must be within work hours"]
    end
  end

  describe "breaks inside hours that end the next day" do
    setup do
      schedule = insert(:availability_schedule)

      day =
        insert(:weekly_availability,
          schedule: schedule,
          day_of_week: 5,
          is_available: true,
          start_time: ~T[22:00:00],
          end_time: ~T[04:00:00],
          ends_next_day: true
        )

      %{day: day}
    end

    test "accepts a break after midnight", %{day: day} do
      attrs = %{weekly_availability_id: day.id, start_time: ~T[01:00:00], end_time: ~T[01:30:00]}
      assert AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs).valid?
    end

    test "accepts a break across midnight", %{day: day} do
      attrs = %{weekly_availability_id: day.id, start_time: ~T[23:30:00], end_time: ~T[00:30:00]}
      assert AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs).valid?
    end

    test "refuses a break outside the hours", %{day: day} do
      attrs = %{weekly_availability_id: day.id, start_time: ~T[05:00:00], end_time: ~T[06:00:00]}
      refute AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs).valid?
    end
  end
end
