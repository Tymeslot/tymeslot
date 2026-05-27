defmodule Tymeslot.Repo.Migrations.CreateAnalyticsEvents do
  use Ecto.Migration

  def change do
    create table(:analytics_events) do
      add :event_type, :string, null: false
      add :path, :string, null: false
      add :meeting_type_id, references(:meeting_types, on_delete: :nilify_all)
      add :user_id, references(:users, on_delete: :nilify_all)
      add :session_id, :string
      add :visitor_hash, :string, null: false
      add :utm_source, :string
      add :utm_medium, :string
      add :utm_campaign, :string
      add :utm_content, :string
      add :utm_term, :string
      add :referrer_host, :string
      add :tracking_params, :map, default: %{}, null: false
      add :user_agent_family, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:analytics_events, [:user_id, :inserted_at])
    create index(:analytics_events, [:meeting_type_id, :inserted_at])
    create index(:analytics_events, [:visitor_hash, :inserted_at])
    create index(:analytics_events, [:inserted_at])
    create index(:analytics_events, [:utm_source])
    create index(:analytics_events, [:utm_campaign])
  end
end
