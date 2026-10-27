defmodule Tymeslot.Repo.Migrations.AddSyncRemindersChangedToProviderCalendarEvents do
  use Ecto.Migration

  # Whether the local change queued on the row edits its reminders, so the
  # replay sends them even when the edit removed every one. The row holds the
  # result of the change, not the change, and a row cached before the sync
  # read alarms holds no reminders whatever its document says.
  def change do
    alter table(:provider_calendar_events) do
      # False for every existing row, which the replay reads as "not known to
      # have changed" and treats as it always has. Postgres 11+ records a
      # non-volatile default in the catalogue instead of rewriting the table,
      # so the lock covers a catalogue update only.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :sync_reminders_changed, :boolean, null: false, default: false
    end
  end
end
