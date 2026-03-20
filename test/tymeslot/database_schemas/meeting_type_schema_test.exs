defmodule Tymeslot.DatabaseSchemas.MeetingTypeSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema

  describe "business rules" do
    test "prevents meetings longer than 8 hours" do
      user = insert(:user)

      attrs = %{
        name: "All Day Meeting",
        duration_minutes: 481,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "must be less than or equal to 480" in errors_on(changeset).duration_minutes
    end

    test "prevents zero-duration meetings" do
      user = insert(:user)

      attrs = %{
        name: "No Time Meeting",
        duration_minutes: 0,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).duration_minutes
    end

    test "prevents duplicate meeting type names per user" do
      user = insert(:user)
      insert(:meeting_type, user: user, name: "Daily Standup", allow_video: false)

      {:error, changeset} =
        %MeetingTypeSchema{}
        |> MeetingTypeSchema.changeset(%{
          name: "Daily Standup",
          duration_minutes: 30,
          user_id: user.id,
          allow_video: false
        })
        |> Repo.insert()

      assert "You already have a meeting type with this name" in errors_on(changeset).user_id
    end

    test "schema allows non-divisible-by-5 durations (form layer enforces this)" do
      user = insert(:user)

      attrs = %{
        name: "Odd Duration",
        duration_minutes: 7,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      assert changeset.valid?
    end

    test "prevents more than three reminders" do
      user = insert(:user)

      attrs = %{
        name: "Reminder Packed",
        duration_minutes: 30,
        user_id: user.id,
        reminder_config: [
          %{value: 15, unit: "minutes"},
          %{value: 30, unit: "minutes"},
          %{value: 1, unit: "hours"},
          %{value: 1, unit: "days"}
        ]
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "cannot have more than 3 reminders" in errors_on(changeset).reminder_config
    end
  end
end
