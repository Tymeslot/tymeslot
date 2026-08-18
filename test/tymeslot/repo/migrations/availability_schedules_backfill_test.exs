defmodule Tymeslot.Repo.Migrations.AvailabilitySchedulesBackfillTest do
  @moduledoc """
  Asserts the schedule migration chain left the database in the shape the
  application now assumes, rather than merely running without crashing.

  The migrations have already run against the test database by the time this
  executes, so the assertions describe the post-migration invariants that must
  hold for any database, including one upgraded from an older release.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :migrations
  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Repo

  test "the profiles table no longer carries the scheduling policy columns" do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_name = 'profiles'
        AND column_name IN ('buffer_minutes', 'min_advance_hours', 'advance_booking_days')
      """)

    assert rows == []
  end

  test "weekly availability and overrides are schedule-scoped, not profile-scoped" do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name, column_name FROM information_schema.columns
      WHERE table_name IN ('weekly_availability', 'availability_overrides')
        AND column_name IN ('profile_id', 'schedule_id')
      ORDER BY table_name, column_name
      """)

    assert rows == [
             ["availability_overrides", "schedule_id"],
             ["weekly_availability", "schedule_id"]
           ]
  end

  test "a profile can hold only one default schedule" do
    profile = insert(:profile)
    {:ok, _default} = Schedules.create_default(profile.id)

    assert_raise Ecto.ConstraintError, fn ->
      # excellent_migrations:safety-assured-for-next-line operation_insert
      Repo.insert!(%AvailabilityScheduleSchema{
        profile_id: profile.id,
        name: "Second default",
        is_default: true
      })
    end
  end

  test "deleting a schedule cascades its weekly rows" do
    profile = insert(:profile)
    {:ok, _default} = Schedules.create_default(profile.id)
    {:ok, extra} = Schedules.create(profile.id, %{name: "Evenings"})

    {:ok, _deleted} = Schedules.delete(extra)

    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM weekly_availability WHERE schedule_id = $1", [extra.id])

    assert count == 0
  end
end
