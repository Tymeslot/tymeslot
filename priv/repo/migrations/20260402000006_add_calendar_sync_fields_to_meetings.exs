defmodule Tymeslot.Repo.Migrations.AddCalendarSyncFieldsToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :calendar_sync_status, :string
      add :calendar_sync_status_dismissed_at, :utc_datetime
      add :provider_event_id, :string
    end

    create index(:meetings, [:calendar_integration_id, :provider_event_id])
  end
end
