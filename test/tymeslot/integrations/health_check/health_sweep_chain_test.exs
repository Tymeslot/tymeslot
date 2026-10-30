defmodule Tymeslot.Integrations.HealthCheck.HealthSweepChainTest do
  @moduledoc """
  The integration health sweep end to end: `IntegrationHealthSweepWorker`
  enqueues an `IntegrationHealthWorker` probe for a due integration, the
  probe reaches the provider, and its verdict is written to the integration's
  health state row. Which integrations the sweep enqueues is covered in
  `SchedulerProbeTimingTest`.

  Runs the real `HealthCheck` (the test config points the worker at a mock)
  with only the Google API module mocked.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory
  import Tymeslot.Integrations.HealthCheckTestSetup

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Workers.{IntegrationHealthSweepWorker, IntegrationHealthWorker}

  setup :verify_on_exit!
  setup :use_real_health_check

  setup do
    CalendarCircuitBreaker.reset(:google)
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")
    {:ok, integration: integration}
  end

  test "a probe that reaches Google records a check on the health state", %{
    integration: integration
  } do
    expect(GoogleCalendarAPIMock, :list_primary_events, fn _integration, _start, _end ->
      {:ok, []}
    end)

    run_sweep_and_probe(integration)

    assert {:ok, state} = IntegrationHealthStateQueries.get(:calendar, integration.id)
    assert %DateTime{} = state.last_check_at
    assert state.status == :healthy
    assert state.successes == 1
    assert state.failures == 0
  end

  test "a probe Google fails records the failure on the health state", %{
    integration: integration
  } do
    expect(GoogleCalendarAPIMock, :list_primary_events, fn _integration, _start, _end ->
      {:error, :network_error, "Request timed out"}
    end)

    run_sweep_and_probe(integration)

    # A first transient failure is retried after five minutes rather than
    # counted towards unhealthy (`Monitor`); the count starts only once the
    # backoff reaches its cap.
    assert {:ok, state} = IntegrationHealthStateQueries.get(:calendar, integration.id)
    assert %DateTime{} = state.last_check_at
    assert state.last_error_class == :transient
    assert state.backoff_ms == :timer.minutes(5)
    assert state.failures == 0
    assert state.status == :healthy
  end

  defp run_sweep_and_probe(integration) do
    assert :ok = perform_job(IntegrationHealthSweepWorker, %{})

    # The sweep seeds the row; nothing has been checked yet.
    assert {:ok, %{last_check_at: nil}} =
             IntegrationHealthStateQueries.get(:calendar, integration.id)

    assert [job] =
             all_enqueued(
               worker: IntegrationHealthWorker,
               args: %{"type" => "calendar", "integration_id" => integration.id}
             )

    assert :ok = perform_job(IntegrationHealthWorker, job.args)
  end
end
