defmodule Tymeslot.Repo.Migrations.AddCalendarRedesignToCalendarPreferences do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # Every default is a constant, which PostgreSQL 11 and later store in the
  # catalogue rather than rewriting the table for. Tymeslot also deploys as a
  # single instance and migrates with the app stopped, so the brief catalogue
  # lock blocks no traffic.

  # The redesigned calendar's per-user choices. `redesign_enabled` picks the
  # calendar surface (false keeps every existing user on the old grid until
  # they opt in); `density` and `fold_night` shape the new grid; `focus_mode`
  # is stored now and gets its control in a later release. Existing rows take
  # the defaults, so no backfill is needed and NOT NULL holds from the start.
  def change do
    alter table(:calendar_preferences) do
      add(:redesign_enabled, :boolean, null: false, default: false)
      add(:density, :string, null: false, default: "comfortable")
      add(:fold_night, :boolean, null: false, default: true)
      add(:focus_mode, :boolean, null: false, default: false)
    end
  end
end
