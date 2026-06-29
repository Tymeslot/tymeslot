defmodule Tymeslot.Repo.Migrations.AddDesktopRemindersToCalendarPreferences do
  use Ecto.Migration

  # Per-user opt-in for browser desktop reminder notifications. A plain boolean
  # with a default backfills every existing row to "off", so no data repair is
  # needed.
  def change do
    alter table(:calendar_preferences) do
      add(:desktop_reminders_enabled, :boolean, null: false, default: false)
    end
  end
end
