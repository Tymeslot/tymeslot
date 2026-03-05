defmodule Tymeslot.Repo.Migrations.CreateTelegramDeliveries do
  use Ecto.Migration

  def change do
    create table(:telegram_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :integration_id, references(:telegram_integrations, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :meeting_id, :binary_id
      add :message_text, :text
      add :response_status, :integer
      add :response_body, :string, size: 2000
      add :error_message, :string
      add :delivered_at, :utc_datetime
      add :attempt_count, :integer, default: 1

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:telegram_deliveries, [:integration_id, :inserted_at])
  end
end
