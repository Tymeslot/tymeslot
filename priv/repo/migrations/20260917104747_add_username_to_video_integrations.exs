defmodule Tymeslot.Repo.Migrations.AddUsernameToVideoIntegrations do
  use Ecto.Migration

  # Nextcloud Talk authenticates with a username and an app password, and no
  # existing credential column names the account the way a username does. The
  # value is stored encrypted, as `calendar_integrations.username_encrypted` is
  # for the CalDAV providers that take the same pair of credentials.
  def change do
    alter table(:video_integrations) do
      add :username_encrypted, :binary
    end
  end
end
