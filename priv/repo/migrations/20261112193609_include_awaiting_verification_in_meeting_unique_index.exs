defmodule Tymeslot.Repo.Migrations.IncludeAwaitingVerificationInMeetingUniqueIndex do
  @moduledoc """
  Makes a booking held for email verification occupy its slot.

  An `awaiting_verification` meeting holds its start time until the attendee
  confirms or the hold expires, so the database must refuse a second live
  booking at that time exactly as it does for a confirmed one. Two partial
  unique indexes encode "occupying", and both gain the status here, in step
  with `Tymeslot.Meetings.MeetingState.occupying/0`:

    * `unique_confirmed_meeting_per_organizer_at_time` on
      `(organizer_user_id, start_time)`, last rebuilt by `20260916121726`;
    * `meetings_invitation_id_occupying_index` on `invitation_id`, from
      `20261106094048` (`Tymeslot.Meetings.InvitationOccupyingIndexTest` pins
      it to `occupying/0`).

  The sweep that expires stale holds filters on the deadline of exactly these
  rows, so a small partial index serves it. It is built `IF NOT EXISTS`, which
  alone would skip an index an interrupted build left invalid and record the
  version anyway, so the planner would ignore it for ever; an invalid one is
  dropped first and built again, as the unique indexes are.

  ## Existing data

  Nothing to repair on a healthy installation: no row can hold the new status
  before this release, so widening a predicate admits nothing that was not
  already indexed. The exception is an installation whose index is invalid or
  missing (an interrupted earlier build): its inserts have not been guarded
  since, so duplicates may exist, and a unique build over them fails. A failed
  migration stops the release booting, so the duplicates are checked first and
  when any exist the migration warns and leaves that index as it found it
  rather than crash-looping the boot. Which of two bookings survives is an
  operator's call; the warning names the rebuild to run afterwards.

  ## Names and locking

  Both names are kept: the schema matches on them to turn a collision into a
  changeset error (see `20260902120100`). Every build and drop runs
  `CONCURRENTLY`, so neither the DDL transaction nor the migration lock can be
  held, and each swap is staged: the new index is built under a temporary name,
  and only once valid is the old one dropped and the new one renamed into
  place. A failed or interrupted build leaves the old index untouched, so the
  table is never unprotected. A leftover staging index is dropped before the
  build, and an index already carrying the target predicate is left alone, so
  re-runs are self-healing no-ops.

  `down/0` swaps both indexes back to their previous predicates and drops the
  sweep index. A meeting held for verification at that point is not in the
  narrower indexes, which is harmless: nothing else reads them.
  """

  use Ecto.Migration

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true

  @slot_status "status IN ('confirmed', 'awaiting_approval')"
  @slot_tail " AND organizer_user_id IS NOT NULL AND reschedule_requested_at IS NULL"
  @invitation_status "status IN ('confirmed', 'pending', 'awaiting_payment', 'awaiting_approval')"
  @invitation_tail " AND invitation_id IS NOT NULL"

  # The widened and the previous predicates differ only in this term, so its
  # presence in the catalogue's rendering of the current predicate tells them
  # apart.
  @term "awaiting_verification"

  @sweep_index :meetings_awaiting_verification_deadline_index

  def up do
    swap(slot_spec(), widen(@slot_status) <> @slot_tail)
    swap(invitation_spec(), widen(@invitation_status) <> @invitation_tail)

    sweep_index = sweep_index()

    if invalid?(@sweep_index), do: drop(sweep_index)
    create_if_not_exists(sweep_index)
  end

  def down do
    drop_if_exists(sweep_index())

    swap(slot_spec(), @slot_status <> @slot_tail)
    swap(invitation_spec(), @invitation_status <> @invitation_tail)
  end

  defp sweep_index do
    index(:meetings, [:verification_deadline_at],
      where: "status = 'awaiting_verification'",
      name: @sweep_index,
      concurrently: true
    )
  end

  defp invalid?(name) do
    %{rows: rows} =
      repo().query!(
        "SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)",
        [Atom.to_string(name)]
      )

    rows == [[false]]
  end

  defp widen(status_clause),
    do: String.replace_suffix(status_clause, ")", ", 'awaiting_verification')")

  defp slot_spec do
    %{
      index: :unique_confirmed_meeting_per_organizer_at_time,
      staging: :unique_confirmed_meeting_per_organizer_at_time_new,
      columns: [:organizer_user_id, :start_time]
    }
  end

  defp invitation_spec do
    %{
      index: :meetings_invitation_id_occupying_index,
      staging: :meetings_invitation_id_occupying_index_new,
      columns: [:invitation_id]
    }
  end

  defp swap(spec, predicate) do
    if current?(spec, predicate), do: :ok, else: rebuild_unless_violated(spec, predicate)
  end

  defp rebuild_unless_violated(spec, predicate) do
    case violating_rows(spec, predicate) do
      0 ->
        rebuild(spec, predicate)

      violating ->
        Logger.warning(
          "Leaving index #{spec.index} as it is: meetings holds #{violating} rows that would " <>
            "violate the unique predicate (#{predicate}). Resolve the duplicates, then rebuild " <>
            "it: DROP INDEX CONCURRENTLY IF EXISTS #{spec.index}; CREATE UNIQUE INDEX " <>
            "CONCURRENTLY #{spec.index} ON meetings (#{Enum.join(spec.columns, ", ")}) " <>
            "WHERE #{predicate};"
        )
    end
  end

  defp rebuild(spec, predicate) do
    drop_if_exists(index(:meetings, spec.columns, name: spec.staging, concurrently: true))

    create(
      unique_index(:meetings, spec.columns,
        where: predicate,
        name: spec.staging,
        concurrently: true
      )
    )

    drop_if_exists(index(:meetings, spec.columns, name: spec.index, concurrently: true))

    # Ecto has no rename for indexes. A rename takes only a brief exclusive
    # lock on the index, not the table, and rewrites nothing.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("ALTER INDEX #{spec.staging} RENAME TO #{spec.index}")
  end

  # `to_regclass/1` returns NULL for a missing relation, so a missing index is
  # no row rather than an error. An invalid index is never current: it is the
  # state an interrupted build leaves behind, and the rebuild is what heals it.
  defp current?(spec, predicate) do
    %{rows: rows} =
      repo().query!(
        "SELECT indisvalid, pg_get_expr(indpred, indrelid) FROM pg_index " <>
          "WHERE indexrelid = to_regclass($1)",
        [Atom.to_string(spec.index)]
      )

    case rows do
      [[true, current]] when is_binary(current) ->
        String.contains?(current, @term) == String.contains?(predicate, @term)

      _missing_or_invalid ->
        false
    end
  end

  # Rows that share a key under the predicate. NULLs never collide in a unique
  # index, and both predicates already exclude a NULL key.
  defp violating_rows(spec, predicate) do
    keys = Enum.join(spec.columns, ", ")

    %{rows: [[count]]} =
      repo().query!("""
      SELECT COALESCE(SUM(n), 0)::bigint FROM (
        SELECT count(*) AS n FROM meetings
        WHERE (#{predicate})
        GROUP BY #{keys}
        HAVING count(*) > 1
      ) AS groups
      """)

    count
  end
end
