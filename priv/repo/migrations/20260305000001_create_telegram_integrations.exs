defmodule Tymeslot.Repo.Migrations.CreateTelegramIntegrations do
  use Ecto.Migration

  def change do
    create table(:telegram_integrations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :bot_mode, :string, null: false, default: "own"
      add :bot_token_encrypted, :binary
      add :chat_id, :string
      add :events, {:array, :string}, null: false, default: []
      add :is_active, :boolean, null: false, default: true
      add :last_triggered_at, :utc_datetime
      add :failure_count, :integer, null: false, default: 0
      add :disabled_at, :utc_datetime
      add :disabled_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:telegram_integrations, [:user_id])
    create index(:telegram_integrations, [:user_id, :is_active], where: "is_active = true")
  end
end
