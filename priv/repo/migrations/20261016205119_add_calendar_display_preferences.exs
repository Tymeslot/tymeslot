defmodule Tymeslot.Repo.Migrations.AddCalendarDisplayPreferences do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # Every default is a constant, which PostgreSQL 11 and later store in the
  # catalogue rather than rewriting the table for. Tymeslot also deploys as a
  # single instance and migrates with the app stopped, so the brief catalogue
  # lock blocks no traffic.

  # The calendar's per-user display choices: `density` and `fold_night`
  # shape the grid; `focus_mode` hides the dashboard menu. Existing rows take
  # the defaults, so no backfill is needed and NOT NULL holds from the start.
  def change do
    alter table(:calendar_preferences) do
      add(:density, :string, null: false, default: "comfortable")
      add(:fold_night, :boolean, null: false, default: true)
      add(:focus_mode, :boolean, null: false, default: false)
    end
  end
end
