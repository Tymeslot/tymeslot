defmodule Tymeslot.Repo.Migrations.AllowNullCalendarPreferencesTimeFormat do
  # Raw SQL throughout, deliberately: only the constraint and the default
  # change, and Ecto's `modify/3` cannot say that without restating the column
  # type, which reads as a type change to both this checker and to anyone
  # reviewing it. ALTER ... DROP NOT NULL / DROP DEFAULT say exactly what
  # happens and nothing more.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  use Ecto.Migration

  @moduledoc """
  Lets `time_format` be NULL, meaning "this organiser has not chosen a clock, so
  follow their language". Until now the column was NOT NULL DEFAULT '12h', which
  cannot express that: an untouched row and a deliberate 12-hour choice were
  indistinguishable, so extending the preference beyond the calendar grid would
  have forced AM/PM on German and French organisers who never asked for it.

  Rows that already exist keep their stored value. They belong to organisers who
  reached the calendar settings modal, so treating that value as chosen is the
  conservative reading, and nothing they currently see changes.
  """

  def up do
    # Both are catalogue-only changes in PostgreSQL: dropping NOT NULL and
    # dropping a default rewrite no rows and take only a brief metadata lock.
    execute("ALTER TABLE calendar_preferences ALTER COLUMN time_format DROP NOT NULL")
    execute("ALTER TABLE calendar_preferences ALTER COLUMN time_format DROP DEFAULT")
  end

  def down do
    # Reinstating NOT NULL needs every row to satisfy it, so the rows that opted
    # into locale-driven formatting fall back to the original default.
    execute("UPDATE calendar_preferences SET time_format = '12h' WHERE time_format IS NULL")
    execute("ALTER TABLE calendar_preferences ALTER COLUMN time_format SET DEFAULT '12h'")
    execute("ALTER TABLE calendar_preferences ALTER COLUMN time_format SET NOT NULL")
  end
end
