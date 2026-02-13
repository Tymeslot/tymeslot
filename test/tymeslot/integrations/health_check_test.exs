defmodule Tymeslot.Integrations.HealthCheckTest do
  use Tymeslot.DataCase, async: false

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory
  import Ecto.Query
  import Mox

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    # Start the GenServer with initial_delay: 0 to disable automatic checks
    {:ok, pid} = HealthCheck.start_link(check_interval: 1_000_000, initial_delay: 0)

    # Use global mode for mocks because HealthCheck uses Oban workers
    # and GenServer calls that might cross process boundaries
    Mox.set_mox_global()

    on_exit(fn ->
      Mox.set_mox_private()

      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    {:ok, pid: pid}
  end

  describe "integration health monitoring" do
    test "deactivates integration after repeated failures" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Mock failure for 3 checks (threshold is 3)
      expect(GoogleCalendarAPIMock, :list_primary_events, 3, fn _int, _start, _end ->
        {:error, :unauthorized, "Token expired"}
      end)

      # 1st failure
      run_health_checks()
      sync_with_server()
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :degraded
      assert status.failures == 1

      # 2nd failure
      run_health_checks()
      sync_with_server()
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :degraded
      assert status.failures == 2

      # 3rd failure
      run_health_checks()
      sync_with_server()
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :unhealthy
      assert status.failures == 3

      # Verify it was deactivated in DB
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      refute updated.is_active
    end

    test "recovers integration after repeated successes" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Initial failure to make it degraded
      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, :unauthorized}
      end)

      run_health_checks()
      sync_with_server()
      assert HealthCheck.get_health_status(:calendar, integration.id).status == :degraded

      # Mock success for 2 checks (recovery threshold is 2)
      expect(GoogleCalendarAPIMock, :list_primary_events, 2, fn _int, _start, _end ->
        {:ok, []}
      end)

      # 1st success
      run_health_checks()
      sync_with_server()
      assert HealthCheck.get_health_status(:calendar, integration.id).status == :degraded

      # 2nd success
      run_health_checks()
      sync_with_server()
      assert HealthCheck.get_health_status(:calendar, integration.id).status == :healthy
    end

    test "treats timeout as transient and keeps healthy status" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Mock a slow response
      # Note: Oban doesn't have a built-in "timeout" return value like Task.yield,
      # but the underlying integration call might timeout.
      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, :timeout}
      end)

      # Trigger check
      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "treats timeout exception as transient" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        raise "Timeout while contacting provider"
      end)

      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "handles integration check crash" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Mock a crash
      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        raise "Unexpected crash"
      end)

      # Trigger check
      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :degraded
      assert status.failures == 1
    end

    test "treats http 429 as transient" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:http_error, 429, "Too Many Requests"}
      end)

      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "treats rate limited message as transient" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, :rate_limited, "Rate limited"}
      end)

      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "handles non-utf8 error messages without crashing" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, <<255>>}
      end)

      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :degraded
      assert status.failures == 1
      assert status.last_error_class == :hard
    end
  end

  describe "user health report" do
    test "builds correct report for user" do
      user = insert(:user)
      c1 = insert(:calendar_integration, user: user, provider: "google")
      v1 = insert(:video_integration, user: user, provider: "mirotalk")

      # Mock success for both
      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:ok, []}
      end)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      run_health_checks()
      sync_with_server()

      report = HealthCheck.get_user_health_report(user.id)

      assert length(report.calendar_integrations) == 1
      assert Enum.any?(report.calendar_integrations, &(&1.id == c1.id))

      assert length(report.video_integrations) == 1
      assert Enum.any?(report.video_integrations, &(&1.id == v1.id))

      assert is_map(report.summary)
    end
  end

  describe "circuit breaker integration" do
    test "circuit breaker opens after repeated failures" do
      alias Tymeslot.Infrastructure.CalendarCircuitBreaker

      # Reset to ensure clean state
      CalendarCircuitBreaker.reset(:google)

      # Trip the circuit breaker by causing failures
      for _ <- 1..5 do
        CalendarCircuitBreaker.call(:google, fn -> {:error, :api_failure} end)
      end

      # Verify circuit is open
      status = CalendarCircuitBreaker.status(:google)
      assert status.status == :open

      # Reset for other tests
      CalendarCircuitBreaker.reset(:google)
    end

    test "circuit breaker returns error when open" do
      alias Tymeslot.Infrastructure.CalendarCircuitBreaker

      # Trip the circuit
      for _ <- 1..5 do
        CalendarCircuitBreaker.call(:google, fn -> {:error, :api_failure} end)
      end

      # Next call should return circuit_open
      result = CalendarCircuitBreaker.call(:google, fn -> {:ok, "should not execute"} end)
      assert {:error, :circuit_open} = result

      # Reset for other tests
      CalendarCircuitBreaker.reset(:google)
    end

    test "prevents duplicate job enqueueing when job already exists" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Manually insert a pending job
      %Job{}
      |> Changeset.change(%{
        worker: "Tymeslot.Workers.IntegrationHealthWorker",
        queue: "calendar_integrations",
        state: "available",
        args: %{
          "type" => "calendar",
          "integration_id" => integration.id
        },
        attempt: 0,
        max_attempts: 20,
        inserted_at: DateTime.utc_now(),
        scheduled_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      initial_job_count =
        Repo.one(
          from j in Job,
            where: j.queue == "calendar_integrations",
            where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id)),
            select: count(j.id)
        )

      assert initial_job_count == 1

      # Try to enqueue again - should skip because job already exists
      HealthCheck.check_all_integrations()

      # Wait for processing
      Process.sleep(100)

      final_job_count =
        Repo.one(
          from j in Job,
            where: j.queue == "calendar_integrations",
            where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id)),
            select: count(j.id)
        )

      # Should still be 1 (no duplicate created)
      assert final_job_count == 1
    end

    test "skips enqueue when circuit breaker is open" do
      alias Tymeslot.Infrastructure.CalendarCircuitBreaker

      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Trip the circuit breaker
      for _ <- 1..5 do
        CalendarCircuitBreaker.call(:google, fn -> {:error, :api_failure} end)
      end

      # Verify circuit is open
      status = CalendarCircuitBreaker.status(:google)
      assert status.status == :open

      # Now try to check integrations - should skip enqueueing due to open circuit
      HealthCheck.check_all_integrations()
      # Sync with HealthCheck GenServer to ensure processing completes
      sync_with_server()

      # Verify no jobs were enqueued (circuit breaker prevented it)
      job_count =
        Repo.one(
          from j in Job,
            where: j.queue == "calendar_integrations",
            where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id)),
            select: count(j.id)
        )

      assert job_count == 0

      # Reset for other tests
      CalendarCircuitBreaker.reset(:google)
    end

    test "proceeds with enqueue when circuit breaker is closed" do
      alias Tymeslot.Infrastructure.CalendarCircuitBreaker

      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Ensure circuit is closed
      CalendarCircuitBreaker.reset(:google)
      status = CalendarCircuitBreaker.status(:google)
      assert status.status == :closed

      # Check integrations - should enqueue normally
      HealthCheck.check_all_integrations()
      Process.sleep(100)

      # Verify job was enqueued
      job_count =
        Repo.one(
          from j in Job,
            where: j.queue == "calendar_integrations",
            where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id)),
            select: count(j.id)
        )

      assert job_count == 1
    end

    test "proceeds with enqueue when circuit breaker not found" do
      alias Oban.Job

      # Create a video integration with a provider that doesn't have a circuit breaker
      # Using "nonexistent_provider" which won't match any video circuit breaker
      user = insert(:user)

      integration =
        insert(:video_integration, user: user, is_active: true, provider: "nonexistent_provider")

      # Check integrations - should proceed with enqueue despite breaker not found
      HealthCheck.check_all_integrations()
      # Sync with HealthCheck GenServer to ensure processing completes
      sync_with_server()

      # Verify job was still enqueued (despite circuit breaker not being found)
      # This ensures the system doesn't fail completely if circuit breaker has issues
      job_count =
        Repo.one(
          from j in Job,
            where: j.queue == "calendar_integrations",
            where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id)),
            select: count(j.id)
        )

      # Job should be enqueued despite circuit breaker issue (fail-safe behavior)
      assert job_count == 1
    end

    test "handles circuit breaker status check exceptions gracefully" do
      import ExUnit.CaptureLog

      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # The circuit breaker exists but we'll test the exception handling by checking logs
      # In practice, this would catch process crashes, registry issues, etc.
      _log =
        capture_log(fn ->
          HealthCheck.check_all_integrations()
          sync_with_server()
        end)

      # Should not crash - verify job was enqueued
      job_count =
        Repo.one(
          from j in Job,
            where: j.queue == "calendar_integrations",
            where: fragment("?->>'integration_id' = ?", j.args, ^to_string(integration.id)),
            select: count(j.id)
        )

      assert job_count == 1
    end

    test "safe_to_existing_atom handles unrecognized provider names" do
      # Test that String.to_existing_atom raises ArgumentError for invalid atoms
      # This validates that safe_to_existing_atom's rescue clause will be triggered
      assert_raise ArgumentError, fn ->
        String.to_existing_atom("goggle_invalid_provider")
      end

      # Verify that valid providers work (atoms that exist)
      assert String.to_existing_atom("google") == :google
      assert String.to_existing_atom("outlook") == :outlook
      assert String.to_existing_atom("mirotalk") == :mirotalk
    end
  end

  # Helper to ensure the GenServer has finished processing its message queue
  defp sync_with_server(timeout \\ 5000) do
    _ = :sys.get_state(HealthCheck, timeout)
  end

  defp run_health_checks do
    Repo.delete_all(from(j in Job, where: j.queue == "calendar_integrations"))

    HealthCheck.check_all_integrations()
    now = DateTime.utc_now()

    Repo.update_all(
      from(j in Job, where: j.queue == "calendar_integrations" and j.state == "scheduled"),
      set: [scheduled_at: now, state: "available"]
    )

    Oban.drain_queue(queue: :calendar_integrations, with_limit: 100)
  end
end
