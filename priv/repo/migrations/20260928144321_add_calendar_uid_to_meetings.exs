defmodule Tymeslot.Repo.Migrations.AddCalendarUidToMeetings do
  use Ecto.Migration

  @moduledoc """
  Gives every meeting a `calendar_uid`: the identifier its event carries in the
  organiser's external calendar, kept apart from the booking's own `uid`.

  The `uid` is a bearer capability. The cancel and reschedule links are built
  from it, so whoever holds it can cancel or move the booking. It used to be
  written to the organiser's calendar as the event's UID too, where every
  delegate, colleague on a shared calendar, forwarded copy and syncing tool
  could read it. From this release the calendar only ever sees `calendar_uid`,
  which grants nothing.

  ## Existing rows

  Every existing meeting gets `calendar_uid = uid`. Its event was written under
  that value (Google `iCalUID`, the CalDAV resource UID, and the attendee's
  `.ics` copy), and inbound sync, busy-period deduplication and CalDAV's
  uid-addressed updates all match the meeting to that event by it. Copying the
  value keeps every one of those matches working with no dual lookup and no
  rewrite on the provider side. Those meetings stay exposed until they are in
  the past; every meeting booked from now on gets a fresh, unrelated value.

  `uid` is `NOT NULL` and unique, so the copy can leave no row null and cannot
  create a duplicate, which is what lets the constraint and the unique index
  follow in the same migration.

  ## Locking

  One transaction, so an installation is never left with a half-filled
  column. The `SET NOT NULL` scan and the non-concurrent index build lock the
  meetings table while they run, which is acceptable because migrations run
  before the application starts (`start.sh` runs them in a one-shot VM and
  starts Phoenix only once they finish), so no request waits on the lock.
  """

  def up do
    alter table(:meetings) do
      add(:calendar_uid, :string)
    end

    # A one-shot copy between two columns of the same row, over a column that is
    # `NOT NULL` and unique; there is no migration DSL form for it.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("UPDATE meetings SET calendar_uid = uid WHERE calendar_uid IS NULL")

    # Every row was filled above, so the scan finds nothing to reject. Raw SQL
    # because `modify/3` restates the column type, which the safety check
    # reads as a type change.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("ALTER TABLE meetings ALTER COLUMN calendar_uid SET NOT NULL")

    # Not concurrent: see "Locking" above.
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(unique_index(:meetings, [:calendar_uid]))
  end

  def down do
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    drop(unique_index(:meetings, [:calendar_uid]))

    alter table(:meetings) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:calendar_uid)
    end
  end
end
