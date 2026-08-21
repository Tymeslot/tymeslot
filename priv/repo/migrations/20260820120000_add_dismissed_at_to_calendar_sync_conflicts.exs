defmodule Tymeslot.Repo.Migrations.AddDismissedAtToCalendarSyncConflicts do
  use Ecto.Migration

  # Marks a conflict as seen by the organiser.
  #
  # The dashboard shows a count of differences that mirroring resolved without
  # asking — a placeholder overwritten, a placeholder withdrawn with its
  # source. The count is the only way an organiser learns those happened at
  # all, so it cannot be derived from a time window: a count that ages out on
  # its own is one that disappears before it is read, and a count that never
  # clears stops being read at all once it is large.
  #
  # Nullable rather than a boolean with a default, because *when* it was
  # dismissed is the half that makes the column debuggable: an organiser
  # reporting "the warning came back" is answered by comparing this against
  # `occurred_at`, which a boolean cannot do.
  #
  # No backfill. Every existing row reads as undismissed, which is the honest
  # answer — nobody has seen them, because until this migration there was no
  # way to say so.
  def change do
    alter table(:calendar_sync_conflicts) do
      add(:dismissed_at, :utc_datetime_usec)
    end

    # Partial, on the undismissed rows only. Every read this serves — the
    # per-link count, the whole-account total, the listing under a card — asks
    # for exactly those, and once an organiser has cleared a long history the
    # dismissed rows are the overwhelming majority of the table. Indexing them
    # would pay for rows no query selects.
    #
    # Named explicitly: the derived name exceeds Postgres' 63-character
    # identifier limit and would be silently truncated, leaving the index under
    # a name no later migration could predict in order to drop it.
    #
    # Built non-concurrently, which takes a write lock for the length of the
    # build. Assured rather than deferred because this table is written only by
    # the mirror engine's conflict path — an append per unresolved divergence,
    # which is rare by construction — so the build is over in well under a
    # second and the writes it blocks are a background worker's, not a
    # request's. CREATE INDEX CONCURRENTLY cannot run inside the transaction a
    # migration runs in, so the alternative is a second migration to buy
    # nothing.
    #
    # excellent_migrations:safety-assured-for-this-file index_not_concurrently
    create(
      index(:calendar_sync_conflicts, [:sync_link_id, :occurred_at],
        where: "dismissed_at IS NULL",
        name: :calendar_sync_conflicts_undismissed_index
      )
    )
  end
end
