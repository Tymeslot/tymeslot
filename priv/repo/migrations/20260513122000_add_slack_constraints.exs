defmodule Tymeslot.Repo.Migrations.AddSlackConstraints do
  use Ecto.Migration

  def up do
    # Self-healing: drop any existing duplicate (user_id, team_id) rows before
    # the unique index is created, keeping the oldest row in each group.
    execute("""
    DELETE FROM slack_integrations
    WHERE team_id IS NOT NULL
      AND id NOT IN (
        SELECT MIN(id) FROM slack_integrations
        WHERE team_id IS NOT NULL
        GROUP BY user_id, team_id
      )
    """)

    # Prevent duplicate connections to the same Slack workspace per user.
    # Partial so that pending stubs (team_id IS NULL) are excluded — they
    # are transient and cleaned up by the OAuth completion flow.
    create unique_index(:slack_integrations, [:user_id, :team_id],
             where: "team_id IS NOT NULL",
             name: :slack_integrations_user_team_unique_index
           )

    # Composite index for delivery log queries that filter by integration and
    # order by time (used by list_deliveries/2 and get_delivery_stats/2).
    create index(:slack_deliveries, [:integration_id, :inserted_at])
  end

  def down do
    drop index(:slack_deliveries, [:integration_id, :inserted_at])
    drop index(:slack_integrations, [:user_id, :team_id], name: :slack_integrations_user_team_unique_index)
  end
end
