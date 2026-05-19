defmodule Tymeslot.Integrations.HealthCheckTestSetup do
  @moduledoc """
  Shared `setup` and helpers for tests that drive the real
  `Tymeslot.Integrations.HealthCheck` GenServer end-to-end.

  Used by both `HealthCheckTest` (classification + reporting) and
  `HealthCheckSchedulerTest` (circuit-breaker + dedup scheduling). The two
  files would otherwise duplicate a ~40-line setup block plus the
  `sync_with_server/1` helper.

  Usage:

      defmodule MyHealthCheckTest do
        use Tymeslot.DataCase, async: false
        import Tymeslot.Integrations.HealthCheckTestSetup

        setup :verify_on_exit!
        setup :start_health_check_server
        # ...
      end
  """

  alias ExUnit.Callbacks
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheckMock

  @doc """
  ExUnit setup callback: starts the real `HealthCheck` GenServer with auto-checks
  disabled, switches Mox to global mode, and restores both on exit.

  Stores the server pid in the test context under `:health_check_pid`.
  """
  @spec start_health_check_server(map()) :: {:ok, [health_check_pid: pid()]}
  def start_health_check_server(_context) do
    # The global test config points health_check_module at HealthCheckMock
    # (for IntegrationHealthWorkerTest). Restore the real module so these tests
    # exercise it end-to-end; undo on exit so other tests are unaffected.
    Application.put_env(:tymeslot, :health_check_module, HealthCheck)

    # initial_delay: 0 disables automatic checks so tests stay deterministic.
    {:ok, pid} = HealthCheck.start_link(check_interval: 1_000_000, initial_delay: 0)

    # Global Mox mode because HealthCheck dispatches across Oban workers and
    # GenServer calls that may cross process boundaries.
    Mox.set_mox_global()

    Callbacks.on_exit(fn ->
      Application.put_env(:tymeslot, :health_check_module, HealthCheckMock)

      Mox.set_mox_private()

      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    {:ok, health_check_pid: pid}
  end

  @doc """
  Blocks until the `HealthCheck` GenServer has finished processing its message
  queue. Use after triggering `check_all_integrations/0` or draining the
  health-check job queue.
  """
  @spec sync_with_server(non_neg_integer()) :: term()
  def sync_with_server(timeout \\ 5_000) do
    :sys.get_state(HealthCheck, timeout)
  end
end
