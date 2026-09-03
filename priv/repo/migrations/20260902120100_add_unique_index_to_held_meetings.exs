defmodule Tymeslot.Repo.Migrations.AddUniqueIndexToHeldMeetings do
  @moduledoc """
  Widens the double-booking guarantee to cover held (`"awaiting_approval"`)
  requests, not just confirmed bookings.

  `20260106132718_add_unique_index_to_confirmed_meetings.exs` added a partial
  unique index over `(organizer_user_id, start_time)` scoped to
  `status = 'confirmed'`, described in its own comment as "a hardware-level
  guarantee for double-booking prevention". Once a meeting type gates its
  bookings behind manual approval, a request occupies its slot the moment it
  is inserted as `"awaiting_approval"` — see
  `Tymeslot.Meetings.MeetingState.@occupying_statuses` — exactly like a
  confirmed booking does, but nothing at the database level stopped two
  concurrent requests from both claiming the same organizer + start_time.
  The application-level conflict check that guards against this is a
  check-then-insert race, which is precisely what a database constraint
  exists to close.

  Two independent partial unique indexes (one scoped to `'confirmed'`, a
  second scoped to `'awaiting_approval'`) would not close that race: each
  only compares rows against others of the *same* status, so a confirmed row
  and a held row could still coexist on the same slot. The fix is a single
  index whose predicate spans both live statuses, so any two rows sharing
  `(organizer_user_id, start_time)` collide in the same index entry the
  moment either one is confirmed or awaiting approval.

  The index keeps its original name
  (`unique_confirmed_meeting_per_organizer_at_time`) even though its
  predicate widens, rather than being replaced by a differently-named index:
  `Tymeslot.Meetings.MeetingSchema.changeset/2` declares
  `unique_constraint([:organizer_user_id, :start_time], name:
  :unique_confirmed_meeting_per_organizer_at_time, ...)`, which lets an
  ordinary `Repo.insert`/`Repo.update` through that changeset surface this
  collision as a normal changeset error rather than an uncaught
  `Ecto.ConstraintError`. Renaming the index would silently break that
  translation for every changeset-driven write, not only the new
  awaiting-approval case this migration adds.

  ## Existing data

  `"awaiting_approval"` is introduced by this feature and has never been
  written by any released version, so no pre-existing row can hold that
  status. The confirmed side was already deduplicated by the index this
  migration widens. Still, per the self-healing rule for constraints on an
  open-source project (we cannot see production data before shipping), the
  UPDATE below is a genuine, harmless-if-empty safety net: it resolves any
  (organizer, start_time) collision across the two live statuses by keeping
  the earliest-inserted row and cancelling the rest, so the index creation
  that follows can never fail against real data.

  ## Locking

  Both the drop and the create run `CONCURRENTLY`, so the migration disables
  the DDL transaction and the migration lock; a large `meetings` table never
  sees a blocking exclusive lock while this runs.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name :unique_confirmed_meeting_per_organizer_at_time

  def up do
    execute("""
    UPDATE meetings m
    SET status = 'cancelled', cancelled_at = COALESCE(m.cancelled_at, NOW())
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY organizer_user_id, start_time
               ORDER BY inserted_at ASC, id ASC
             ) AS rn
      FROM meetings
      WHERE status IN ('confirmed', 'awaiting_approval')
        AND organizer_user_id IS NOT NULL
    ) dupes
    WHERE m.id = dupes.id AND dupes.rn > 1
    """)

    drop_if_exists(
      index(:meetings, [:organizer_user_id, :start_time],
        name: @index_name,
        concurrently: true
      )
    )

    create(
      unique_index(:meetings, [:organizer_user_id, :start_time],
        where: "status IN ('confirmed', 'awaiting_approval') AND organizer_user_id IS NOT NULL",
        name: @index_name,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:meetings, [:organizer_user_id, :start_time],
        name: @index_name,
        concurrently: true
      )
    )

    create(
      unique_index(:meetings, [:organizer_user_id, :start_time],
        where: "status = 'confirmed' AND organizer_user_id IS NOT NULL",
        name: @index_name,
        concurrently: true
      )
    )
  end
end
