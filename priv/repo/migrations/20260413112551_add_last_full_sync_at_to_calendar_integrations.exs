defmodule Tymeslot.Repo.Migrations.AddLastFullSyncAtToCalendarIntegrations do
  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add :last_full_sync_at, :utc_datetime
    end
  end
end
