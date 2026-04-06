defmodule Tymeslot.Repo.Migrations.AddUserFkToIntegrationHealthStates do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM integration_health_states
    WHERE user_id NOT IN (SELECT id FROM users)
    """)

    alter table(:integration_health_states) do
      modify :user_id, references(:users, on_delete: :delete_all),
        from: :bigint
    end
  end

  def down do
    drop constraint(:integration_health_states, "integration_health_states_user_id_fkey")

    alter table(:integration_health_states) do
      modify :user_id, :bigint, from: references(:users, on_delete: :delete_all)
    end
  end
end
