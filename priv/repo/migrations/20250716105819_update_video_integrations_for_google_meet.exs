defmodule Tymeslot.Repo.Migrations.UpdateVideoIntegrationsForGoogleMeet do
  use Ecto.Migration

  def change do
    # Add new fields for Google Meet OAuth integration
    alter table(:video_integrations) do
      add :access_token_encrypted, :binary
      add :refresh_token_encrypted, :binary
      add :token_expires_at, :utc_datetime
      add :oauth_scope, :string
    end

    # Add index for token expiration queries
    create index(:video_integrations, [:token_expires_at])
  end
end
