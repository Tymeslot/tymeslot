defmodule Tymeslot.Repo.Migrations.AddCalendarPreferencesSettings do
  use Ecto.Migration

  def change do
    alter table(:calendar_preferences) do
      add :week_start_day, :string, null: false, default: "monday"
      add :time_format, :string, null: false, default: "12h"
      add :show_week_numbers, :boolean, null: false, default: false
      add :show_weekends, :boolean, null: false, default: true
    end
  end
end
