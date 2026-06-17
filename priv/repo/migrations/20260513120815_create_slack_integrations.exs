defmodule Tymeslot.Repo.Migrations.CreateSlackIntegrations do
  use Ecto.Migration

  def change do
    create table(:slack_integrations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # "oauth" | "webhook_url"
      add :app_mode, :string, null: false

      # OAuth mode fields
      add :bot_token_encrypted, :binary
      add :team_id, :string
      add :team_name, :string
      add :channel_id, :string
      add :channel_name, :string
      # Slack user who installed
      add :authed_user_id, :string
      # comma-separated scopes returned
      add :scope, :string

      # Webhook URL mode fields
      add :webhook_url_encrypted, :binary
      # parsed from URL or user-provided label
      add :webhook_channel_hint, :string

      # Common fields
      add :events, {:array, :string}, null: false, default: []
      add :is_active, :boolean, null: false, default: true
      add :last_triggered_at, :utc_datetime_usec
      add :failure_count, :integer, null: false, default: 0
      add :disabled_at, :utc_datetime_usec
      add :disabled_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:slack_integrations, [:user_id])
    create index(:slack_integrations, [:is_active])

    create constraint(:slack_integrations, :app_mode_must_be_valid,
             check: "app_mode IN ('oauth', 'webhook_url')"
           )
  end
end
