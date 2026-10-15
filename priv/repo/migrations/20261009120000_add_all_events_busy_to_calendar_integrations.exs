defmodule Tymeslot.Repo.Migrations.AddAllEventsBusyToCalendarIntegrations do
  use Ecto.Migration

  @moduledoc """
  Lets a calendar subscription count every one of its events as busy,
  whatever the feed says about them.

  Holiday and school-holiday feeds mark their events free (`TRANSP:TRANSPARENT`)
  so that they do not show as busy in the calendars they are subscribed in,
  which also keeps them from blocking any availability. With the flag on, a
  subscription's events block regardless. Every existing row gets `false` and
  so behaves exactly as before.
  """

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # Migrations run offline: start.sh executes them in a one-shot VM before
  # Phoenix starts, so no request contends for the lock. The default is a
  # constant, which Postgres 11+ records in the catalogue without rewriting
  # the table.

  def change do
    alter table(:calendar_integrations) do
      add(:all_events_busy, :boolean, null: false, default: false)
    end
  end
end
