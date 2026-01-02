defmodule Tymeslot.Repo.Migrations.AddCalendarTrackingToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      # Track which calendar integration created this meeting
      add :calendar_integration_id, references(:calendar_integrations, on_delete: :nilify_all)
      
      # Track the specific calendar path/ID within the integration
      add :calendar_path, :string
      
      # Link meetings to users properly
      add :organizer_user_id, references(:users, on_delete: :nilify_all)
    end

    # Add indexes for better query performance
    create index(:meetings, [:calendar_integration_id])
    create index(:meetings, [:organizer_user_id])
    create index(:meetings, [:calendar_integration_id, :uid])
  end
end