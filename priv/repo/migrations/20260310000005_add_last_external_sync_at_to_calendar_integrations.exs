defmodule Tymeslot.Repo.Migrations.AddLastExternalSyncAtToCalendarIntegrations do
  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add :last_external_sync_at, :utc_datetime
    end
  end
end
