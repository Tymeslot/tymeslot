defmodule Tymeslot.Repo.Migrations.AddPrimaryCalendarIntegrationToUsers do
  use Ecto.Migration

  def up do
    alter table(:profiles) do
      add :primary_calendar_integration_id, references(:calendar_integrations, on_delete: :nilify_all)
    end

    create index(:profiles, [:primary_calendar_integration_id])

    # Set primary integration for existing users with calendar integrations
    execute """
    UPDATE profiles 
    SET primary_calendar_integration_id = (
      SELECT ci.id 
      FROM calendar_integrations ci 
      WHERE ci.user_id = profiles.user_id 
        AND ci.is_active = true 
      ORDER BY ci.inserted_at ASC 
      LIMIT 1
    )
    WHERE EXISTS (
      SELECT 1 
      FROM calendar_integrations ci2 
      WHERE ci2.user_id = profiles.user_id 
        AND ci2.is_active = true
    )
    """
  end

  def down do
    drop index(:profiles, [:primary_calendar_integration_id])
    
    alter table(:profiles) do
      remove :primary_calendar_integration_id
    end
  end
end
