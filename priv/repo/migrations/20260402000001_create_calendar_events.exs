defmodule Tymeslot.Repo.Migrations.CreateCalendarEvents do
  use Ecto.Migration

  def change do
    create table(:calendar_events) do
      add :uid, :string, null: false
      add :calendar_integration_id, references(:calendar_integrations, on_delete: :delete_all), null: false
      add :calendar_path, :string
      add :provider_event_id, :string
      add :title, :string
      add :start_at, :utc_datetime, null: false
      add :end_at, :utc_datetime, null: false
      add :all_day, :boolean, default: false, null: false
      add :location, :string
      add :description, :text
      add :attendees, {:array, :map}, default: []
      add :recurrence_rule, :string
      add :recurring_event_id, :string
      add :status, :string
      add :raw_data, :map
      add :etag, :string
      add :synced_at, :utc_datetime

      timestamps()
    end

    create unique_index(:calendar_events, [:calendar_integration_id, :uid])
    create index(:calendar_events, [:calendar_integration_id, :start_at, :end_at])
    create index(:calendar_events, [:calendar_integration_id, :provider_event_id])
  end
end
