defmodule Tymeslot.Repo.Migrations.AddVideoIntegrationToMeetingTypes do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add :video_integration_id, references(:video_integrations, on_delete: :nilify_all)
    end

    create index(:meeting_types, [:video_integration_id])
  end
end