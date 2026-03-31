defmodule Tymeslot.Repo.Migrations.AddCaldavSyncColumnsToCalendarIntegrations do
  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add :caldav_sync_tier, :integer
      add :caldav_sync_token, :string
    end
  end
end
