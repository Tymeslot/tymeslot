defmodule Tymeslot.Repo.Migrations.AllowClearedEventColourOverrides do
  # Raw SQL states the one change exactly: `modify/3` would read as a column
  # type change. Dropping NOT NULL takes a brief lock and rewrites nothing.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  @moduledoc """
  Lets an external event's override hold a `NULL` colour, meaning "no
  colour": the organiser cleared it, and the host calendar may still carry
  the old one until the write-back has cleared it there.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE event_colour_overrides ALTER COLUMN colour DROP NOT NULL")
  end

  # A cleared override has no colour to restore, so rolling back drops it
  # before the column is made NOT NULL again.
  def down do
    execute("DELETE FROM event_colour_overrides WHERE colour IS NULL")
    execute("ALTER TABLE event_colour_overrides ALTER COLUMN colour SET NOT NULL")
  end
end
