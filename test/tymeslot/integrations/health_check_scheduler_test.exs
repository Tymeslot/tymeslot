defmodule Tymeslot.Integrations.HealthCheckSchedulerTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory
  import Tymeslot.Integrations.HealthCheckTestSetup
  import Ecto.Query
  import ExUnit.CaptureLog
  import Mox

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.ProviderHelpers
  alias Tymeslot.Repo

  setup :verify_on_exit!
  setup :start_health_check_server

  describe "circuit breaker integration" do
    test "circuit breaker opens after repeated failures" do
      # Reset to ensure clean state
      CalendarCircuitBreaker.reset(:google)

      # Trip the circuit breaker by causing failures
      for _i <- 1..5 do
        CalendarCircuitBreaker.call(:google, fn -> {:provider_error, :api_failure} end)
      end

      # Verify circuit is open
      status = CalendarCircuitBreaker.status(:google)
      assert status.status == :open

      # Reset for other tests
      CalendarCircuitBreaker.reset(:google)
    end

    test "circuit breaker returns error when open" do
      # Trip the circuit
      for _i <- 1..5 do
        CalendarCircuitBreaker.call(:google, fn -> {:provider_error, :api_failure} end)
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
      sync_with_server()

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
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Trip the circuit breaker
      for _i <- 1..5 do
        CalendarCircuitBreaker.call(:google, fn -> {:provider_error, :api_failure} end)
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
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Ensure circuit is closed
      CalendarCircuitBreaker.reset(:google)
      status = CalendarCircuitBreaker.status(:google)
      assert status.status == :closed

      # Check integrations - should enqueue normally
      HealthCheck.check_all_integrations()
      sync_with_server()

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
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # The circuit breaker exists but we'll test the exception handling by checking logs
      # In practice, this would catch process crashes, registry issues, etc.
      _captured_log =
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

    test "custom video integration enqueues without unknown circuit breaker warning" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          is_active: true,
          provider: "custom",
          custom_meeting_url: "https://example.com"
        )

      log =
        capture_log(fn ->
          HealthCheck.check_all_integrations()
          sync_with_server()
        end)

      # :custom has no circuit breaker — scheduler should proceed silently
      refute log =~ "Unknown circuit breaker status"

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
      # An unknown name would raise ArgumentError from String.to_existing_atom;
      # the rescue clause turns it into nil and logs instead.
      log =
        capture_log(fn ->
          assert ProviderHelpers.safe_to_existing_atom("goggle_invalid_provider") == nil
        end)

      assert log =~ "Provider name not recognised"

      assert ProviderHelpers.safe_to_existing_atom("google") == :google
      assert ProviderHelpers.safe_to_existing_atom("outlook") == :outlook
      assert ProviderHelpers.safe_to_existing_atom("mirotalk") == :mirotalk
      assert ProviderHelpers.safe_to_existing_atom(nil) == nil
    end
  end
end
