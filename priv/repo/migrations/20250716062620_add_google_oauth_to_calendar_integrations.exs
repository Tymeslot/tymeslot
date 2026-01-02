defmodule Tymeslot.Repo.Migrations.AddGoogleOauthToCalendarIntegrations do
  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add :access_token_encrypted, :binary
      add :refresh_token_encrypted, :binary
      add :token_expires_at, :utc_datetime
      add :oauth_scope, :text
    end

    # Update provider constraint to include google
    execute(
      "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check",
      "ALTER TABLE calendar_integrations ADD CONSTRAINT calendar_integrations_provider_check CHECK (provider = 'radicale')"
    )

    execute(
      "ALTER TABLE calendar_integrations ADD CONSTRAINT calendar_integrations_provider_check CHECK (provider IN ('radicale', 'google'))",
      "ALTER TABLE calendar_integrations DROP CONSTRAINT calendar_integrations_provider_check"
    )
  end
end
