defmodule Tymeslot.Repo.Migrations.AddStatusCheckToIntegrationHealthStates do
  use Ecto.Migration

  @moduledoc """
  Closes the `integration_health_states.status` vocabulary at the database
  layer. `HealthCheck.HealthStatus` has always treated
  `healthy | degraded | unhealthy` as the only valid values, but nothing
  below the changeset enforced it: `IntegrationHealthStateQueries.update_fields/3`
  writes via a raw `update_all` with no validation. Backfills any row already
  outside that set to `degraded` — a safe default that self-heals on the
  row's next probe — before adding the constraint.
  """

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so the ACCESS EXCLUSIVE lock the constraint
  # takes to validate existing rows blocks no live traffic. Revisit this if a
  # deployment target ever migrates against a running instance. The raw UPDATE
  # is the backfill that constraint needs: it has no changeset to run through,
  # and it must repair the rows before the constraint can accept them.
  def up do
    execute("""
    UPDATE integration_health_states
    SET status = 'degraded'
    WHERE status NOT IN ('healthy', 'degraded', 'unhealthy')
    """)

    create(
      constraint(:integration_health_states, :status_must_be_known,
        check: "status IN ('healthy', 'degraded', 'unhealthy')"
      )
    )
  end

  def down do
    drop(constraint(:integration_health_states, :status_must_be_known))
  end
end
