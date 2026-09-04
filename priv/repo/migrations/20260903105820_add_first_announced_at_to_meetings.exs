defmodule Tymeslot.Repo.Migrations.AddFirstAnnouncedAtToMeetings do
  use Ecto.Migration

  # `announced_at` is a claim, not a record: a reschedule that sends a
  # confirmed booking back into the approval gate clears it, so that the
  # second approval can claim the `meeting.created` fan-out again. That leaves
  # nothing on the row saying the booking was ever a live meeting, which is
  # exactly the question the refund rule has to answer when such a request is
  # then declined. This column is that record — stamped beside the first
  # claim and never cleared.

  def up do
    alter table(:meetings) do
      add(:first_announced_at, :utc_datetime)
    end

    # Every meeting announced before this column existed was announced, and a
    # confirmed one can be rescheduled into the gate the day after this
    # deploys. Without the backfill those bookings would read as never
    # announced and be refunded in full automatically, which is the behaviour
    # the column exists to prevent.
    #
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("UPDATE meetings SET first_announced_at = announced_at WHERE announced_at IS NOT NULL")
  end

  def down do
    alter table(:meetings) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:first_announced_at)
    end
  end
end
