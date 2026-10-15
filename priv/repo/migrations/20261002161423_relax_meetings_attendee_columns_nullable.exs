defmodule Tymeslot.Repo.Migrations.RelaxMeetingsAttendeeColumnsNullable do
  @moduledoc """
  Repair migration: makes `meetings.attendee_name` and
  `meetings.attendee_email` nullable.

  A group meeting holds no attendee on the meeting row; its bookers live in
  `meeting_participants`. The original `create_meetings` migration is patched
  to declare both columns nullable for fresh installs, but a database that
  already ran it keeps the old `NOT NULL`, because Ecto never re-runs an
  applied migration. This heals those databases.

  `DROP NOT NULL` is a no-op on a column that is already nullable, so this is
  safe on fresh installs and idempotent across any prior state.
  """

  use Ecto.Migration

  # The check flags every `execute/1` because it cannot parse the SQL. Both
  # statements are `ALTER TABLE ... DROP NOT NULL`, which only clears an
  # attribute flag in the catalogue: no table scan, no rewrite, constant time
  # regardless of row count.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  def up do
    execute("ALTER TABLE meetings ALTER COLUMN attendee_name DROP NOT NULL")
    execute("ALTER TABLE meetings ALTER COLUMN attendee_email DROP NOT NULL")
  end

  # Intentionally a no-op: re-imposing NOT NULL would fail on any group
  # meeting created with no attendee.
  def down, do: :ok
end
