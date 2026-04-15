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
      upsert_health(user.id, integration.id,
        failures: SyncGating.threshold(),
        last_error_class: "hard"
      )

      ids = SyncGating.paused_integration_ids(:calendar)
      assert MapSet.member?(ids, integration.id)
    end

    test "does not include integrations whose last error was transient",
         %{user: user, integration: integration} do
      upsert_health(user.id, integration.id,
        failures: SyncGating.threshold() * 5,
        last_error_class: "transient"
      )

      refute MapSet.member?(
               SyncGating.paused_integration_ids(:calendar),
               integration.id
             )
    end

    test "does not include integrations below the threshold",
         %{user: user, integration: integration} do
      upsert_health(user.id, integration.id,
        failures: SyncGating.threshold() - 1,
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

      upsert_health(user.id, integration.id, failures: 3, last_error_class: "hard")

      assert MapSet.member?(
               SyncGating.paused_integration_ids(:calendar),
               integration.id
             )
    end
  end

  describe "paused?/2" do
    test "returns false for a healthy integration", %{integration: integration} do
      refute SyncGating.paused?(:calendar, integration.id)
    end

    test "returns true once the integration's failures exceed the threshold",
         %{user: user, integration: integration} do
      upsert_health(user.id, integration.id,
        failures: SyncGating.threshold() + 1,
        last_error_class: "hard"
      )

      assert SyncGating.paused?(:calendar, integration.id)
    end
  end

  defp upsert_health(user_id, integration_id, fields) do
    attrs =
      Map.merge(
        %{
          user_id: user_id,
          status: "unhealthy",
          failures: 0,
          successes: 0,
          backoff_ms: 1_800_000,
          last_check_at: DateTime.utc_now()
        },
        Map.new(fields)
      )

    {:ok, _record} = IntegrationHealthStateQueries.upsert(:calendar, integration_id, attrs)
  end
end
