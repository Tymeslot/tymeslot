defmodule Tymeslot.Repo.Migrations.AddStatusCheckToMeetingGuests do
  use Ecto.Migration

  @moduledoc """
  Closes the `meeting_guests.status` vocabulary at the database layer,
  matching the `Ecto.Enum` the schema now declares. `Ecto.Enum` raises on load
  for a value outside its list, so a stray row would break every read of it.

  Backfills any row already outside the set to `pending` before adding the
  constraint. That is how such a row already read: the RSVP summary bucketed
  every unknown value as pending, and only `declined` gives a seat back, so
  the guest keeps the seat they held and can still answer from their link.
  The column is `NOT NULL`, so there are no NULLs to repair.
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
  def up do
    execute("""
    UPDATE meeting_guests
    SET status = 'pending'
    WHERE status NOT IN ('pending', 'accepted', 'declined')
    """)

    create(
      constraint(:meeting_guests, :meeting_guests_status_must_be_known,
        check: "status IN ('pending', 'accepted', 'declined')"
      )
    )
  end

  def down do
    drop(constraint(:meeting_guests, :meeting_guests_status_must_be_known))
  end
end
