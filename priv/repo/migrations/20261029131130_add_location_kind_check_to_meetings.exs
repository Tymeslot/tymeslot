defmodule Tymeslot.Repo.Migrations.AddLocationKindCheckToMeetings do
  use Ecto.Migration

  @moduledoc """
  Closes the `meetings.location_kind` vocabulary at the database layer,
  matching the `Ecto.Enum` the schema now declares. `Ecto.Enum` raises on load
  for a value outside its list, so a stray row would break every read of it.

  Backfills any row already outside the set to NULL before adding the
  constraint. NULL is what a meeting booked before the column existed holds,
  and every reader already treats an unknown kind exactly as it treats NULL:
  the emails fall through to inferring the kind from the meeting's other
  fields, and the booking page's in-person confirmation matches neither. The
  column is nullable and NULL stays valid.
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
  @known "'video', 'in_person', 'phone', 'custom'"

  def up do
    execute("""
    UPDATE meetings
    SET location_kind = NULL
    WHERE location_kind IS NOT NULL
      AND location_kind NOT IN (#{@known})
    """)

    create(
      constraint(:meetings, :meetings_location_kind_must_be_known,
        check: "location_kind IS NULL OR location_kind IN (#{@known})"
      )
    )
  end

  def down do
    drop(constraint(:meetings, :meetings_location_kind_must_be_known))
  end
end
