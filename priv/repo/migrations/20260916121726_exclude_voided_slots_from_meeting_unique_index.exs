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

  Nothing to repair on a healthy installation: the new predicate only removes
  rows from the index, so no row a valid index admitted can violate it.

  The exception is an installation whose index is invalid or missing, which is
  what an interrupted `20260902120100` leaves behind. Its inserts have not been
  guarded since, so duplicates may exist, and a unique build over them fails.
  A failed migration stops the release booting, and `start.sh` migrates before
  it serves, so that failure is a crash loop. The duplicates are therefore
  checked first, and when any exist the migration warns and leaves the index
  as it found it rather than failing. Deciding which of two bookings survives
  is an operator's call, not a migration's; the warning names the rebuild to
  run once they have decided.

  The reverse can happen at runtime once the migration has run, which is
  intended: after someone has taken the voided time, the original attendee
  picking that same time again collides. `Bookings.Reschedule` runs the
  conflict check first and answers `:slot_taken`; the index is the backstop
  for the race between them. Rolling back with such a pair present is the same
  problem in the other direction, and `down/0` answers it the same way: it
  warns and keeps the narrower index rather than cancelling a booking to make
  room.

  ## Name and locking

  The name is kept: `MeetingSchema.changeset/2` translates a collision into a
  changeset error by matching on it, and a renamed index would surface every
  collision as an uncaught `Ecto.ConstraintError` instead (see
  `20260902120100`).

  Every build and drop runs `CONCURRENTLY`, so neither the DDL transaction nor
  the migration lock can be held. That is also why the swap is staged: the new
  index is built under a temporary name first, and only once it is valid is
  the old one dropped and the new one renamed into place. A build that fails
  or is interrupted at any point leaves the old index exactly as it was, so
  the table is never unprotected. Dropping first would have removed the guard
  before the replacement existed, and a failed build then left none at all.

  The staging makes re-runs self-healing too. A leftover staging index, valid
  or not, is dropped before the build, and when the final index is already
  valid with the target predicate the migration does nothing, so a run that
  was interrupted after the rename records its version on the next attempt
  without rebuilding.
  """

  use Ecto.Migration

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index :unique_confirmed_meeting_per_organizer_at_time
  @staging :unique_confirmed_meeting_per_organizer_at_time_new
  @columns [:organizer_user_id, :start_time]

  @live "status IN ('confirmed', 'awaiting_approval') AND organizer_user_id IS NOT NULL"
  @voidable @live <> " AND reschedule_requested_at IS NULL"

  # The two predicates differ only in this term, so its presence in the
  # catalogue's rendering of the current predicate is what tells them apart.
  @voidable_term "reschedule_requested_at"

  def up, do: swap_to(@voidable)

  def down, do: swap_to(@live)

  defp swap_to(predicate) do
    if current?(predicate), do: :ok, else: rebuild_unless_violated(predicate)
  end

  defp rebuild_unless_violated(predicate) do
    case violating_rows(predicate) do
      0 ->
        rebuild(predicate)

      violating ->
        Logger.warning(
          "Leaving index #{@index} as it is: meetings holds #{violating} rows that would " <>
            "violate the unique predicate (#{predicate}). Resolve the duplicates, then rebuild " <>
            "it: DROP INDEX CONCURRENTLY IF EXISTS #{@index}; CREATE UNIQUE INDEX CONCURRENTLY " <>
            "#{@index} ON meetings (organizer_user_id, start_time) WHERE #{predicate};"
        )
    end
  end

  defp rebuild(predicate) do
    drop_if_exists(index(:meetings, @columns, name: @staging, concurrently: true))

    create(
      unique_index(:meetings, @columns, where: predicate, name: @staging, concurrently: true)
    )

    drop_if_exists(index(:meetings, @columns, name: @index, concurrently: true))

    # Ecto has no rename for indexes. A rename takes only a brief exclusive
    # lock on the index, not the table, and rewrites nothing.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("ALTER INDEX #{@staging} RENAME TO #{@index}")
  end

  # `to_regclass/1` returns NULL for a missing relation, so a missing index is
  # no row rather than an error. An invalid index is never current: it is the
  # state an interrupted build leaves behind, and the rebuild is what heals it.
  defp current?(predicate) do
    %{rows: rows} =
      repo().query!(
        "SELECT indisvalid, pg_get_expr(indpred, indrelid) FROM pg_index " <>
          "WHERE indexrelid = to_regclass($1)",
        [Atom.to_string(@index)]
      )

    case rows do
      [[true, current]] when is_binary(current) ->
        String.contains?(current, @voidable_term) ==
          String.contains?(predicate, @voidable_term)

      _ ->
        false
    end
  end

  # Rows that share a key under the predicate. NULLs never collide in a unique
  # index, and the predicate already excludes a NULL organizer.
  defp violating_rows(predicate) do
    %{rows: [[count]]} =
      repo().query!("""
      SELECT COALESCE(SUM(n), 0)::bigint FROM (
        SELECT count(*) AS n FROM meetings
        WHERE (#{predicate})
        GROUP BY organizer_user_id, start_time
        HAVING count(*) > 1
      ) AS groups
      """)

    count
  end
end
