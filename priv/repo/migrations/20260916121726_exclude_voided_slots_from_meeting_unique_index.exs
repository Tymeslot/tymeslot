defmodule Tymeslot.Repo.Migrations.ExcludeVoidedSlotsFromMeetingUniqueIndex do
  @moduledoc """
  Stops a slot voided by a host's reschedule request from blocking a new
  booking at the same start time.

  When a host asks an attendee to pick a new time, `Bookings.RescheduleRequest`
  stamps `reschedule_requested_at` and leaves `status` alone. The application
  already treats that slot as free: `MeetingState.where_slot_live/1` excludes
  such rows from every conflict query, so the booking page offers the time
  again. The partial unique index from `20260902120100` did not agree. Its
  predicate knows only the status, so the voided row, still `confirmed`, kept
  its index entry, and the next booking at that start time passed the conflict
  check and then failed on insert.

  Adding `reschedule_requested_at IS NULL` makes the database's notion of a
  live slot match `where_slot_live/1`.

  ## Existing data

  Nothing to repair. The new predicate only removes rows from the index, so no
  existing data can violate it.

  The reverse can now happen at runtime, which is intended: once someone has
  taken the voided time, the original attendee picking that same time again
  collides. `Bookings.Reschedule` runs the conflict check first and answers
  `:slot_taken`; the index is the backstop for the race between them.

  ## Name and locking

  The name is kept: `MeetingSchema.changeset/2` translates a collision into a
  changeset error by matching on it, and a renamed index would surface every
  collision as an uncaught `Ecto.ConstraintError` instead (see
  `20260902120100`).

  Drop and create both run `CONCURRENTLY`, so neither the DDL transaction nor
  the migration lock can be held. Dropping first also makes an interrupted run
  heal itself: a half-built index left invalid is dropped and rebuilt by the
  next attempt, rather than skipped as `IF NOT EXISTS` would.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name :unique_confirmed_meeting_per_organizer_at_time

  def up do
    rebuild(
      "status IN ('confirmed', 'awaiting_approval') AND organizer_user_id IS NOT NULL " <>
        "AND reschedule_requested_at IS NULL"
    )
  end

  # Restoring the narrower index fails if a voided slot has since been booked
  # by someone else. That is left to fail loudly rather than cancelling either
  # meeting to make room: a rollback must not destroy bookings.
  def down do
    rebuild("status IN ('confirmed', 'awaiting_approval') AND organizer_user_id IS NOT NULL")
  end

  defp rebuild(predicate) do
    drop_if_exists(
      index(:meetings, [:organizer_user_id, :start_time], name: @index_name, concurrently: true)
    )

    create(
      unique_index(:meetings, [:organizer_user_id, :start_time],
        where: predicate,
        name: @index_name,
        concurrently: true
      )
    )
  end
end
