defmodule Tymeslot.Repo.Migrations.CreateSlackDeliveries do
  use Ecto.Migration

  def change do
    create table(:slack_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :integration_id, references(:slack_integrations, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :meeting_id, :string
      # the Block Kit payload sent
      add :message_blocks, :map
      add :response_status, :integer
      add :response_body, :text
      add :error_message, :text
      add :delivered_at, :utc_datetime_usec
      add :attempt_count, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:slack_deliveries, [:integration_id])
    create index(:slack_deliveries, [:event_type])
    create index(:slack_deliveries, [:inserted_at])
  end
end
