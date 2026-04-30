defmodule Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :queries

  import Tymeslot.Factory
  import Tymeslot.TestFixtures

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema

  setup do
    user = create_user_fixture()
    %{user: user}
  end

  defp insert_unhealthy_row(user, integration_id) do
    {:ok, _row} =
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: "calendar",
        integration_id: integration_id,
        user_id: user.id,
        status: "unhealthy",
        failures: 5,
        consecutive_hard_failures: 5,
        successes: 0,
        backoff_ms: :timer.hours(1),
        last_check_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        last_error_class: "hard",
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -3 * 24 * 3600, :second),
        notification_sent_at: DateTime.add(DateTime.utc_now(), -2 * 24 * 3600, :second)
      })
      |> Repo.insert()
  end

  describe "reset/2" do
    test "writes a known-healthy baseline over an unhealthy row", %{user: user} do
      insert_unhealthy_row(user, 42)

      {1, nil} = IntegrationHealthStateQueries.reset(:calendar, 42)

      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 42)

      assert row.status == "healthy"
      assert row.failures == 0
      assert row.consecutive_hard_failures == 0
      assert row.successes == 2
      assert row.last_error_class == nil
      assert row.became_unhealthy_at == nil
      assert row.notification_sent_at == nil
      assert row.backoff_ms == 1_800_000
    end

    test "is a no-op when no row exists", %{user: _user} do
      assert {0, nil} = IntegrationHealthStateQueries.reset(:calendar, 9999)
    end

    test "scopes by integration_type", %{user: user} do
      insert_unhealthy_row(user, 7)

      {0, nil} = IntegrationHealthStateQueries.reset(:video, 7)

      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 7)
      assert row.status == "unhealthy"
    end
  end

  describe "list_unhealthy_for_user/1" do
    defp insert_health_row(user, integration_id, type, status) do
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: type,
        integration_id: integration_id,
        user_id: user.id,
        status: status
      })
      |> Repo.insert!()
    end

    test "returns rows for active integrations only", %{user: user} do
      active = insert(:calendar_integration, user: user, is_active: true)
      inactive = insert(:calendar_integration, user: user, is_active: false)

      insert_health_row(user, active.id, "calendar", "unhealthy")
      insert_health_row(user, inactive.id, "calendar", "unhealthy")

      ids =
        user.id
        |> IntegrationHealthStateQueries.list_unhealthy_for_user()
        |> Enum.map(& &1.integration_id)

      assert active.id in ids
      refute inactive.id in ids
    end

    test "ignores orphaned rows whose integration row no longer exists", %{user: user} do
      insert_health_row(user, 999_999, "calendar", "unhealthy")

      assert IntegrationHealthStateQueries.list_unhealthy_for_user(user.id) == []
    end

    test "ignores healthy and degraded rows even when integration is active", %{user: user} do
      active = insert(:calendar_integration, user: user, is_active: true)
      insert_health_row(user, active.id, "calendar", "healthy")
      insert_health_row(user, active.id + 1_000_000, "calendar", "degraded")

      assert IntegrationHealthStateQueries.list_unhealthy_for_user(user.id) == []
    end
  end
end
