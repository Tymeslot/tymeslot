defmodule Tymeslot.Repo.Migrations.AddGoogleWebhookColumnsToCalendarIntegrations do
  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add :google_channel_id, :string
      add :google_channel_resource_id, :string
      add :google_channel_expires_at, :utc_datetime
      add :google_channel_secret, :string
      add :google_sync_token, :string
      add :last_google_notification_at, :utc_datetime
    end

    create index(:calendar_integrations, [:google_channel_id])
  end
end
