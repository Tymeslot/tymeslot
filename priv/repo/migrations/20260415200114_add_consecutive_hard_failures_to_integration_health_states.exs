defmodule Tymeslot.Repo.Migrations.AddConsecutiveHardFailuresToIntegrationHealthStates do
  use Ecto.Migration

  def up do
    alter table(:integration_health_states) do
      add :consecutive_hard_failures, :integer, null: false, default: 0
    end

    # Best-effort heuristic backfill: rows whose last error was hard are assumed
    # to have had only hard failures contributing to their current count. Rows
    # with a transient last error reset to 0 because we cannot tell how many of
    # their accumulated failures were hard.
    execute("""
    UPDATE integration_health_states
    SET consecutive_hard_failures = CASE
      WHEN last_error_class = 'hard' THEN failures
      ELSE 0
    END
    """)
  end

  def down do
    alter table(:integration_health_states) do
      remove :consecutive_hard_failures
    end
  end
end
