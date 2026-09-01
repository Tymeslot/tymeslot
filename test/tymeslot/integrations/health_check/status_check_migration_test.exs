defmodule Tymeslot.Integrations.HealthCheck.StatusCheckMigrationTest do
  @moduledoc """
  Verifies `20260830065420_add_status_check_to_integration_health_states`
  backfills any out-of-vocabulary `status` value to `degraded` and then
  closes the column with a CHECK constraint, so a raw write can no longer
  poison the row the way `IntegrationHealthStateQueries.update_fields/3` can
  today.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_830_065_420

  test "backfills an out-of-vocabulary status to degraded and re-closes the constraint" do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user)

    {:ok, record} =
      IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

    # Roll the constraint back so the raw write below (which the constraint
    # exists precisely to reject) can poison the row the way a pre-migration
    # database could.
    MigrationRunner.down!(@version)

    {1, _nil} =
      IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
        status: "some_future_status"
      )

    MigrationRunner.up!(@version)

    reloaded = Repo.reload!(record)
    assert reloaded.status == "degraded"

    # The constraint is back: a raw write outside the vocabulary is now
    # rejected at the database rather than silently accepted.
    assert_raise Postgrex.Error, ~r/status_must_be_known/, fn ->
      IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
        status: "still_not_a_real_status"
      )
    end
  end
end
