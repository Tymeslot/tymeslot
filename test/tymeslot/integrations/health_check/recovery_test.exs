defmodule Tymeslot.Integrations.HealthCheck.RecoveryTest do
  @moduledoc """
  Covers `HealthCheck.mark_user_recovered/2` and `mark_synced_successfully/2` —
  the two entry points that allow user-driven success signals to clear stale
  unhealthy state without waiting up to an hour for the next scheduled probe.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Tymeslot.TestFixtures

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup do
    user = create_user_fixture()
    %{user: user}
  end

  defp insert_unhealthy_row(user, type, integration_id) do
    {:ok, row} =
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: type,
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

    row
  end

  describe "mark_user_recovered/2" do
    test "resets the health row to a healthy baseline", %{user: user} do
      insert_unhealthy_row(user, "calendar", 200)

      :ok = HealthCheck.mark_user_recovered(:calendar, 200)

      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 200)
      assert row.status == "healthy"
      assert row.failures == 0
      assert row.consecutive_hard_failures == 0
      assert row.became_unhealthy_at == nil
      assert row.notification_sent_at == nil
    end

    test "enqueues an immediate verification probe", %{user: user} do
      insert_unhealthy_row(user, "calendar", 201)

      :ok = HealthCheck.mark_user_recovered(:calendar, 201)

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => 201}
      )
    end

    test "is safe to call when no row exists" do
      assert :ok = HealthCheck.mark_user_recovered(:calendar, 9_999_999)

      # Probe is still enqueued — orchestration handles missing integrations
      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => 9_999_999}
      )
    end
  end

  describe "mark_synced_successfully/2" do
    test "resets the health row but does not enqueue a probe", %{user: user} do
      insert_unhealthy_row(user, "calendar", 300)

      :ok = HealthCheck.mark_synced_successfully(:calendar, 300)

      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 300)
      assert row.status == "healthy"
      assert row.became_unhealthy_at == nil

      refute_enqueued(worker: IntegrationHealthWorker)
    end
  end
end
