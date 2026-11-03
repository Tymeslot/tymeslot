defmodule Tymeslot.Repo.Migrations.AddStatusCheckToMeetings do
  use Ecto.Migration

  @moduledoc """
  Closes the `meetings.status` vocabulary at the database layer, matching the
  `Ecto.Enum` the schema now declares. `Ecto.Enum` raises on load for a value
  outside its list, so a stray row would break every read of it, and with it
  every list, conflict check and sweep that touches the row.

  Backfills any row already outside the set to `cancelled` before adding the
  constraint, stamping `cancelled_at` where it is missing. Before this change
  such a row matched none of the status groupings, so it already occupied no
  slot, scheduled no reminders and expected no calendar event. `cancelled` is
  the status that keeps it that way: it is released and terminal, so the row
  can never block a booking, be reminded about, or be moved, confirmed or
  cancelled again. Any other value would turn an unreadable row into a live
  booking nobody made. The column is `NOT NULL`, so there are no NULLs to
  repair.
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
  @known """
  'pending', 'awaiting_payment', 'awaiting_approval', 'confirmed', 'cancelled', \
  'completed', 'expired', 'reschedule_requested'\
  """

  def up do
    execute("""
    UPDATE meetings
    SET status = 'cancelled', cancelled_at = COALESCE(cancelled_at, NOW())
    WHERE status NOT IN (#{@known})
    """)

    create(
      constraint(:meetings, :meetings_status_must_be_known, check: "status IN (#{@known})")
    )
  end

  def down do
    drop(constraint(:meetings, :meetings_status_must_be_known))
  end
end
