defmodule Tymeslot.Repo.Migrations.AddRemovedCalendarsToCalendarIntegrations do
  @moduledoc """
  Backing column for the `embeds_many(:removed_calendars, ...)` on calendar
  integrations: the calendars Tymeslot stopped using because the calendar
  server no longer has them, kept until the owner dismisses the notice.

  Existing rows start with an empty list, which is what they would have had:
  nothing has been recorded before this column existed.
  """

  use Ecto.Migration

  # PostgreSQL 11+ stores a non-volatile default in the catalogue rather than
  # rewriting the table, so this is a metadata-only change. Migrations also run
  # offline here (`start.sh` runs them in a one-shot VM and only starts Phoenix
  # once they finish), so no live traffic waits on the lock either way.
  def change do
    alter table(:calendar_integrations) do
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :removed_calendars, {:array, :map}, null: false, default: []
    end
  end
end
