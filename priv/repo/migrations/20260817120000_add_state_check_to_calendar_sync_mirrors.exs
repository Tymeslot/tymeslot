defmodule Tymeslot.Repo.Migrations.AddStateCheckToCalendarSyncMirrors do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # The lifecycle states a mirror row may hold, enforced by the database rather
  # than by the changeset alone.
  #
  # `CalendarSyncMirrorSchema.changeset/2` already runs `validate_inclusion`,
  # but the changeset is not what every write goes through.
  # `CalendarSyncMirrorQueries.mark_pending_delete_for_link/1` moves a whole
  # link's rows with a single `update_all` — deliberately, because a link with a
  # year of history holds thousands of mappings and the transition carries no
  # per-row decision — and `update_all` runs no changeset at all. So does any
  # repair run by hand against the deployed node. Nothing below the application
  # stood between a misspelt state and the column.
  #
  # A row holding one is invisible rather than noisy. Every reader of this
  # column branches on an exact string: the reconcile sweep's
  # `list_pending_delete_for_link/1`, the link query that decides a disabled
  # link still has withdrawals outstanding, and the engine's withdrawal guard,
  # which matches the state in a function head and falls through to the rewrite
  # clause when it does not match. A row that says `activ` is therefore not
  # found by the sweep, not recognised as pending withdrawal, and not protected
  # from the rewrite — while the placeholder it names sits on the organiser's
  # calendar with nothing looking for it.
  #
  # Safe to add without a backfill or a `NOT VALID`/`VALIDATE` split. Every
  # existing row was written through the changeset, so all of them already hold
  # one of these three values and the validating scan finds no violation. The
  # table is small — mappings are per-link, not per-event-occurrence — so the
  # brief ACCESS EXCLUSIVE lock the scan takes is measured in milliseconds.
  # The constraint admits exactly what `@states` admits, so no currently
  # writable row becomes unwritable.
  #
  # Named explicitly. The derived name would be
  # `calendar_sync_mirrors_calendar_sync_mirrors_state_check`, which is within
  # Postgres' 63-character limit but repeats the table; the short form is what
  # the schema's `check_constraint/3` names and what an error must match.
  def change do
    create(
      constraint(:calendar_sync_mirrors, :calendar_sync_mirrors_state_check,
        check: "state IN ('active', 'pending_delete', 'failed')"
      )
    )
  end
end
