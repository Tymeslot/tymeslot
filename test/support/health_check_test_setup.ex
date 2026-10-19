defmodule Tymeslot.Integrations.HealthCheckTestSetup do
  @moduledoc """
  Shared `setup` for tests that drive the real
  `Tymeslot.Integrations.HealthCheck` end-to-end.

  Used by both `HealthCheckTest` (classification + reporting) and
  `HealthCheckSchedulerTest` (circuit-breaker + dedup scheduling).

  Usage:

      defmodule MyHealthCheckTest do
        use Tymeslot.DataCase, async: false
        import Tymeslot.Integrations.HealthCheckTestSetup

        setup :verify_on_exit!
        setup :use_real_health_check
        # ...
      end
  """

  alias ExUnit.Callbacks
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheckMock

  @doc """
  ExUnit setup callback: points `:health_check_module` at the real
  `HealthCheck` instead of the mock, switches Mox to global mode (the checks
  run in Oban jobs, outside the test process), and restores both on exit.
  """
  @spec use_real_health_check(map()) :: :ok
  def use_real_health_check(_context) do
    # The global test config points health_check_module at HealthCheckMock
    # (for IntegrationHealthWorkerTest). Restore the real module so these tests
    # exercise it end-to-end; undo on exit so other tests are unaffected.
    Application.put_env(:tymeslot, :health_check_module, HealthCheck)
    Mox.set_mox_global()

    Callbacks.on_exit(fn ->
      Application.put_env(:tymeslot, :health_check_module, HealthCheckMock)
      Mox.set_mox_private()
    end)

    :ok
  end
end
