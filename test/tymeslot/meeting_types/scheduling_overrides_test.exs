defmodule Tymeslot.MeetingTypes.SchedulingOverridesTest do
  @moduledoc """
  A meeting type's overrides of its schedule's scheduling rules: the bounds
  they are held to, and the longest booking window the calendar prefetch must
  cover.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types
  @moduletag :availability

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Validation.Constraints

  describe "changeset/3" do
    setup do
      %{user: insert(:user)}
    end

    defp changeset(user, attrs) do
      MeetingTypeSchema.changeset(
        %MeetingTypeSchema{},
        Map.merge(%{name: "Quick support", duration_minutes: 30, user_id: user.id}, attrs)
      )
    end

    test "leaves every rule nil, inheriting the schedule's, when none is given", %{user: user} do
      changeset = changeset(user, %{})

      assert changeset.valid?

      assert Enum.reject(
               Constraints.scheduling_policy_fields(),
               &is_nil(Changeset.get_field(changeset, &1))
             ) == []
    end

    test "accepts zero buffers and zero notice", %{user: user} do
      assert changeset(user, %{
               buffer_before_minutes: 0,
               buffer_after_minutes: 0,
               min_advance_hours: 0
             }).valid?
    end

    test "holds each rule to the bounds a schedule has", %{user: user} do
      changeset =
        changeset(user, %{
          buffer_before_minutes: 121,
          buffer_after_minutes: -1,
          min_advance_hours: 169,
          advance_booking_days: 0
        })

      errors = errors_on(changeset)

      assert Map.has_key?(errors, :buffer_before_minutes)
      assert Map.has_key?(errors, :buffer_after_minutes)
      assert Map.has_key?(errors, :min_advance_hours)
      assert Map.has_key?(errors, :advance_booking_days)
    end

    test "the database refuses a rule out of bounds even past the changeset's validation", %{
      user: user
    } do
      # Forced in after validation, as a write that skips the changeset's
      # number checks would be; the check constraint is the backstop.
      for {field, value} <- [
            buffer_before_minutes: 121,
            buffer_after_minutes: -1,
            min_advance_hours: 169,
            advance_booking_days: 0
          ] do
        changeset = user |> changeset(%{}) |> Changeset.force_change(field, value)

        assert {:error, refused} = Repo.insert(changeset)
        assert Map.has_key?(errors_on(refused), field)
      end
    end
  end

  describe "max_advance_booking_days_override/1" do
    test "is nil when no meeting type sets its own window" do
      user = insert(:user)
      insert(:meeting_type, user: user)

      assert MeetingTypes.max_advance_booking_days_override(user.id) == nil
    end

    test "is the longest window an active meeting type sets, ignoring inactive ones" do
      user = insert(:user)
      other = insert(:user)

      insert(:meeting_type, user: user, advance_booking_days: 120)
      insert(:meeting_type, user: user, advance_booking_days: 200)
      insert(:meeting_type, user: user, advance_booking_days: 365, is_active: false)
      insert(:meeting_type, user: other, advance_booking_days: 300)

      assert MeetingTypes.max_advance_booking_days_override(user.id) == 200
    end
  end
end
