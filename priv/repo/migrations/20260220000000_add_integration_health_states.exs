defmodule Tymeslot.Repo.Migrations.AddIntegrationHealthStates do
  use Ecto.Migration

  def change do
    create table(:integration_health_states) do
      add :integration_type, :string, null: false
      add :integration_id, :bigint, null: false
      add :user_id, :bigint, null: false
      add :status, :string, null: false, default: "healthy"
      add :failures, :integer, null: false, default: 0
      add :successes, :integer, null: false, default: 0
      add :backoff_ms, :integer, null: false, default: 1_800_000
      add :last_check_at, :utc_datetime_usec
      add :last_error_class, :string
      add :became_unhealthy_at, :utc_datetime_usec
      add :notification_sent_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create unique_index(:integration_health_states, [:integration_type, :integration_id])
    create index(:integration_health_states, [:user_id])
    create index(:integration_health_states, [:user_id, :status])
  end
end
