defmodule Tymeslot.Repo.Migrations.AddNeedsReauthToCalendarIntegrations do
  use Ecto.Migration

  # Flag set by sync workers when a credential on the integration cannot be
  # decrypted (e.g. SECRET_KEY_BASE rotated without keeping the old key on the
  # keyring). Surfaced in the dashboard so the user can reconnect.
  def change do
    alter table(:calendar_integrations) do
      add :needs_reauth, :boolean, null: false, default: false
    end
  end
end
