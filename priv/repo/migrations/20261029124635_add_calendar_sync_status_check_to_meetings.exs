defmodule Tymeslot.Repo.Migrations.AddCalendarSyncStatusCheckToMeetings do
  use Ecto.Migration

  @moduledoc """
  Closes the `meetings.calendar_sync_status` vocabulary at the database layer,
  matching the `Ecto.Enum` the schema now declares. `Ecto.Enum` raises on load
  for a value outside its list, so a stray row would break every read of it.

  Backfills any row already outside the set to NULL before adding the
  constraint. An unknown value already matched no reader: the dashboard card
  showed no banner and no sync or move flow acted on it. NULL (no flag) keeps
  that behaviour exactly. The column is nullable and NULL stays valid.
  """

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so the ACCESS EXCLUSIVE lock the constraint
  # takes to validate existing rows blocks no live traffic. Revisit this if a
  # deployment target ever migrates against a running instance. The raw UPDATE
  # is the backfill that constraint needs: it has no changeset to run through,
  # and it must repair the rows before the constraint can accept them.
  @known "'externally_deleted', 'externally_modified'"

  def up do
    execute("""
    UPDATE meetings
    SET calendar_sync_status = NULL
    WHERE calendar_sync_status IS NOT NULL
      AND calendar_sync_status NOT IN (#{@known})
    """)

    create(
      constraint(:meetings, :meetings_calendar_sync_status_must_be_known,
        check: "calendar_sync_status IS NULL OR calendar_sync_status IN (#{@known})"
      )
    )
  end

  def down do
    drop(constraint(:meetings, :meetings_calendar_sync_status_must_be_known))
  end
end
