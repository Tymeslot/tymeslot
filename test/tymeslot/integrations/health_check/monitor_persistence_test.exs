defmodule Tymeslot.Integrations.HealthCheck.MonitorPersistenceTest do
  @moduledoc """
  Covers the database-backed side of the monitor: reading and writing health
  state, decoding unexpected column values, and cleaning up orphaned rows.

  The in-memory state machine lives in `MonitorHealthStateTest` and
  `MonitorTransitionTest`.
  """
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.HealthCheck.Monitor

  describe "get_state/3 and put_state/3" do
    test "get_state creates a default healthy record for unknown integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      health = Monitor.get_state(:calendar, integration.id, user.id)

      assert health.status == :healthy
      assert health.failures == 0
      assert health.successes == 0
      assert health.last_check_at == nil
    end

    test "get_state returns existing state from DB" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          status: "degraded",
          failures: 2,
          successes: 0,
          backoff_ms: :timer.minutes(5),
          last_check_at: DateTime.utc_now()
        )

      health = Monitor.get_state(:calendar, integration.id, user.id)

      assert health.status == :degraded
      assert health.failures == 2
    end

    test "put_state persists health state to DB" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      health_state = %{
        Monitor.initial_state()
        | failures: 1,
          status: :degraded,
          last_check_at: DateTime.utc_now()
      }

      assert {1, _nil} = Monitor.put_state(:calendar, integration.id, health_state)

      {:ok, record} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert record.status == "degraded"
      assert record.failures == 1
    end

    # The email handler stamps `notification_sent_at` once the unhealthy email
    # has gone out. A probe that read the row before that must not write the
    # stale value back, or the 30-day cooldown is lost.
    test "put_state leaves a notification stamp made after the probe read the row" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      read_by_probe = Monitor.get_state(:calendar, integration.id, user.id)
      stamped_at = DateTime.utc_now(:second)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          notification_sent_at: stamped_at
        )

      probed = Monitor.update_health(read_by_probe, {:ok, :probe_succeeded})
      assert {1, _nil} = Monitor.put_state(:calendar, integration.id, probed)

      {:ok, record} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert DateTime.compare(record.notification_sent_at, stamped_at) == :eq
    end

    # A sync that read the row as unhealthy, then failed below the streak
    # threshold, must not bring the status back after the probe recorded a
    # recovery in between: that stale status and `became_unhealthy_at` are
    # what send an owner an "unhealthy" email just after their integration
    # recovered.
    test "put_sync_state below the streak threshold leaves a recovery the probe recorded" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      became_unhealthy_at = DateTime.add(DateTime.utc_now(), -3, :day)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          status: "unhealthy",
          became_unhealthy_at: became_unhealthy_at
        )

      read_by_sync = Monitor.get_state(:calendar, integration.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          status: "healthy",
          became_unhealthy_at: nil
        )

      failed_sync = Monitor.record_sync_failure(read_by_sync)
      assert {1, _nil} = Monitor.put_sync_state(:calendar, integration.id, failed_sync)

      {:ok, record} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert record.status == "healthy"
      assert record.became_unhealthy_at == nil
      assert record.consecutive_sync_failures == 1
    end

    test "put_state returns {0, nil} when no record exists" do
      health_state = %{
        Monitor.initial_state()
        | failures: 1,
          status: :degraded,
          last_check_at: DateTime.utc_now()
      }

      assert {0, nil} = Monitor.put_state(:calendar, -1, health_state)
    end

    test "put_state persists video integration state to DB" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:video, integration.id, user.id)

      health_state = %{Monitor.initial_state() | failures: 2, status: :degraded}

      assert {1, _nil} = Monitor.put_state(:video, integration.id, health_state)

      {:ok, record} = IntegrationHealthStateQueries.get(:video, integration.id)
      assert record.status == "degraded"
      assert record.failures == 2
    end
  end

  describe "from_db_record/1" do
    test "degrades an unrecognised status to :degraded and logs it, instead of raising" do
      # A row's status can no longer be poisoned through the app (the
      # database CHECK constraint added alongside this change rejects it,
      # see `StatusCheckMigrationTest`), so the only way left to exercise
      # this read path is a record that never touched the database at all —
      # standing in for a row a hand-edited backup or a rolled-back release
      # could still produce.
      record = %IntegrationHealthStateSchema{
        integration_type: "calendar",
        integration_id: 123,
        status: "some_future_status"
      }

      log =
        capture_log(fn ->
          assert Monitor.from_db_record(record).status == :degraded
        end)

      assert log =~ "Unrecognised integration health status"
    end

    test "handles unexpected last_error_class string without crashing" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          last_error_class: "unknown_class"
        )

      health = Monitor.get_state(:calendar, integration.id, user.id)
      assert health.last_error_class == :hard
    end
  end

  describe "orphaned health state cleanup" do
    test "delete_orphaned removes health states for deleted integrations" do
      user = insert(:user)
      cal = insert(:calendar_integration, user: user)
      vid = insert(:video_integration, user: user)

      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, cal.id, user.id)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:video, vid.id, user.id)

      # Create orphaned records (integration IDs that don't exist)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, -999, user.id)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:video, -998, user.id)

      {deleted, _nil} = IntegrationHealthStateQueries.delete_orphaned()

      assert deleted == 2

      # Real records still exist
      assert {:ok, _record} = IntegrationHealthStateQueries.get(:calendar, cal.id)
      assert {:ok, _record} = IntegrationHealthStateQueries.get(:video, vid.id)

      # Orphaned records are gone
      assert {:error, :not_found} = IntegrationHealthStateQueries.get(:calendar, -999)
      assert {:error, :not_found} = IntegrationHealthStateQueries.get(:video, -998)
    end

    test "delete_orphaned returns {0, nil} when no orphans exist" do
      user = insert(:user)
      cal = insert(:calendar_integration, user: user)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, cal.id, user.id)

      assert {0, _nil} = IntegrationHealthStateQueries.delete_orphaned()
    end
  end
end
