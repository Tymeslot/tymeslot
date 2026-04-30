defmodule Tymeslot.Integrations.CalendarManagementTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.IntegrationHealthWorker

  # ---------------------------------------------------------------------------
  # toggle_calendar_integration/1
  # ---------------------------------------------------------------------------

  describe "toggle_calendar_integration/1" do
    test "enqueues an IntegrationHealthWorker probe when reactivating (inactive → active)" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: false)

      assert {:ok, updated} = CalendarManagement.toggle_calendar_integration(integration)
      assert updated.is_active

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when deactivating (active → inactive)" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert {:ok, updated} = CalendarManagement.toggle_calendar_integration(integration)
      refute updated.is_active

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # update_calendar_integration/2
  # ---------------------------------------------------------------------------

  describe "update_calendar_integration/2" do
    test "enqueues an IntegrationHealthWorker probe and resets the health row when credential fields are present" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Seed an unhealthy row so we can verify the reset fires.
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: "calendar",
        integration_id: integration.id,
        user_id: user.id,
        status: "unhealthy",
        failures: 5,
        consecutive_hard_failures: 5,
        successes: 0,
        backoff_ms: :timer.hours(1)
      })
      |> Repo.insert!()

      assert {:ok, _updated} =
               CalendarManagement.update_calendar_integration(integration, %{
                 password_encrypted: "new-encrypted-password"
               })

      # Health row is reset to a healthy baseline.
      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert row.status == "healthy"
      assert row.failures == 0

      # Immediate verification probe is enqueued.
      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when no credential fields are present" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, name: "Before")

      assert {:ok, _updated} =
               CalendarManagement.update_calendar_integration(integration, %{name: "After"})

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # mark_sync_success/1
  # ---------------------------------------------------------------------------

  describe "mark_sync_success/1" do
    test "resets the health state row without enqueueing a probe" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Seed an unhealthy row.
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: "calendar",
        integration_id: integration.id,
        user_id: user.id,
        status: "unhealthy",
        failures: 3,
        consecutive_hard_failures: 3,
        successes: 0,
        backoff_ms: :timer.hours(1)
      })
      |> Repo.insert!()

      assert {:ok, _updated} = CalendarManagement.mark_sync_success(integration)

      # Health row is reset to a healthy baseline.
      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert row.status == "healthy"
      assert row.failures == 0

      # A successful sync proves health — no redundant probe should be enqueued.
      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => integration.id}
      )
    end
  end
end
