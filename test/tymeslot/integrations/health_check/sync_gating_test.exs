defmodule Tymeslot.Integrations.HealthCheck.SyncGatingTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.SyncGating

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user)
    {:ok, user: user, integration: integration}
  end

  describe "paused_integration_ids/1" do
    test "returns an empty set when no integrations have exceeded the threshold" do
      assert MapSet.size(SyncGating.paused_integration_ids(:calendar)) == 0
    end

    test "includes integrations with enough consecutive hard failures",
         %{user: user, integration: integration} do
      seed_health(user.id, integration.id,
        failures: SyncGating.threshold(),
        consecutive_hard_failures: SyncGating.threshold(),
        last_error_class: "hard"
      )

      ids = SyncGating.paused_integration_ids(:calendar)
      assert MapSet.member?(ids, integration.id)
    end

    test "does not include integrations whose last error was transient",
         %{user: user, integration: integration} do
      seed_health(user.id, integration.id,
        failures: SyncGating.threshold() * 5,
        consecutive_hard_failures: 0,
        last_error_class: "transient"
      )

      refute MapSet.member?(
               SyncGating.paused_integration_ids(:calendar),
               integration.id
             )
    end

    test "does not include integrations below the threshold",
         %{user: user, integration: integration} do
      seed_health(user.id, integration.id,
        failures: SyncGating.threshold() - 1,
        consecutive_hard_failures: SyncGating.threshold() - 1,
        last_error_class: "hard"
      )

      refute MapSet.member?(
               SyncGating.paused_integration_ids(:calendar),
               integration.id
             )
    end

    test "does not gate an integration with high failures but low consecutive hard failures",
         %{user: user, integration: integration} do
      # Regression: an integration with many accumulated failures (transient history)
      # and only 2 consecutive hard failures must not be paused at a threshold of 10.
      seed_health(user.id, integration.id,
        failures: 10,
        consecutive_hard_failures: 2,
        last_error_class: "hard"
      )

      refute MapSet.member?(
               SyncGating.paused_integration_ids(:calendar),
               integration.id
             )
    end

    test "honours a lowered threshold configured via application env",
         %{user: user, integration: integration} do
      original = Application.get_env(:tymeslot, :sync_pause_hard_failure_threshold)
      Application.put_env(:tymeslot, :sync_pause_hard_failure_threshold, 3)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:tymeslot, :sync_pause_hard_failure_threshold)
          value -> Application.put_env(:tymeslot, :sync_pause_hard_failure_threshold, value)
        end
      end)

      seed_health(user.id, integration.id,
        failures: 3,
        consecutive_hard_failures: 3,
        last_error_class: "hard"
      )

      assert MapSet.member?(
               SyncGating.paused_integration_ids(:calendar),
               integration.id
             )
    end
  end

  # Seeds the row through the production write path: `get_or_init/3` inserts
  # the baseline, `update_fields/3` applies the failure history under test.
  defp seed_health(user_id, integration_id, fields) do
    {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, integration_id, user_id)

    {1, nil} =
      IntegrationHealthStateQueries.update_fields(
        :calendar,
        integration_id,
        Keyword.merge([status: "unhealthy", last_check_at: DateTime.utc_now()], fields)
      )
  end
end
