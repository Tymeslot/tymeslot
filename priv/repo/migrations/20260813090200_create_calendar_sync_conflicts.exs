defmodule Tymeslot.Repo.Migrations.CreateCalendarSyncConflicts do
  use Ecto.Migration

  # Both assurances apply because the table is created empty in this same
  # migration: there are no rows for the index to lock out, and the reference
  # is declared as part of CREATE TABLE rather than added to a table already
  # holding data, so nothing a running deploy reads is locked. Building the
  # index concurrently is not possible here in any case, since CREATE INDEX
  # CONCURRENTLY cannot run inside the transaction a migration runs in.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # Append-only audit of every non-trivial mirror resolution: both sides
  # changed, the mirror was edited on the host, a delete raced an update, or
  # the write failed outright.
  #
  # Separate from the mirror row on purpose. A mirror row holds current state
  # and is overwritten on every successful write, so a conflict recorded there
  # is erased by the very next sync — which is exactly when an organiser starts
  # asking why their placeholder moved. The history is what makes the answer
  # available, and it must outlive the state that produced it.
  #
  # Growth is bounded by pruning on the DataRetentionWorker pattern rather than
  # by refusing to write rows: dropping a conflict at the moment it happens
  # trades a diagnosis nobody can recover for disk nobody is short of.
  def change do
    create table(:calendar_sync_conflicts) do
      add(:sync_link_id, references(:calendar_sync_links, on_delete: :delete_all), null: false)

      add(:source_uid, :string, null: false)

      # both_changed / mirror_edited / delete_race / write_failed
      add(:kind, :string, null: false)

      # source_won / deletion_won / skipped
      add(:resolution, :string, null: false)

      # The timestamps and etags compared, and the provider error when one
      # applies. Free-form because a useful conflict record is whatever the
      # branch that produced it had in hand, and pinning columns now would mean
      # a migration per new conflict kind.
      add(:detail, :map, null: false, default: %{})

      # Distinct from inserted_at: a conflict detected during a reconciliation
      # sweep happened when the divergence occurred, not when the sweep noticed.
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    # Named explicitly: the derived name exceeds Postgres' 63-character
    # identifier limit and would be silently truncated, leaving the index under
    # a name no later migration could predict in order to drop it.
    #
    # Serves both readers: the dashboard listing one link's history newest
    # first, and the retention prune deleting everything older than a cutoff.
    create(
      index(:calendar_sync_conflicts, [:sync_link_id, :occurred_at],
        name: :calendar_sync_conflicts_link_occurred_at_index
      )
    )
  end
end
