defmodule Tymeslot.Repo.Migrations.AddNeedsReauthToVideoIntegrations do
  use Ecto.Migration

  # Flag set when a credential on the integration cannot be decrypted (e.g.
  # SECRET_KEY_BASE rotated without keeping the old key on the keyring).
  # Surfaced in the dashboard so the user can reconnect.
  def change do
    alter table(:video_integrations) do
      add :needs_reauth, :boolean, null: false, default: false
      add :sync_error, :text
    end
  end
end
