defmodule Tymeslot.Repo.Migrations.AddUniqueActiveVideoIntegrationPerUserProvider do
  use Ecto.Migration

  def up do
    # Deactivate duplicates: for each (user_id, provider) group with multiple
    # active rows, keep only the most recently updated one active.
    execute("""
    UPDATE video_integrations
    SET is_active = false, updated_at = NOW()
    WHERE id IN (
      SELECT id FROM (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY user_id, provider
                 ORDER BY updated_at DESC
               ) AS rn
        FROM video_integrations
        WHERE is_active = true
      ) ranked
      WHERE rn > 1
    )
    """)

    create(
      unique_index(:video_integrations, [:user_id, :provider],
        where: "is_active = true",
        name: :one_active_integration_per_user_provider
      )
    )
  end

  def down do
    drop(index(:video_integrations, [:user_id, :provider], name: :one_active_integration_per_user_provider))
  end
end
