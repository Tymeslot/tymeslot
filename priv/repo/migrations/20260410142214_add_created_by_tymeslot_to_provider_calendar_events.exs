defmodule Tymeslot.Repo.Migrations.AddCreatedByTymeslotToProviderCalendarEvents do
  use Ecto.Migration

  def change do
    alter table(:provider_calendar_events) do
      add :created_by_tymeslot, :boolean, null: false, default: false
    end
  end
end
