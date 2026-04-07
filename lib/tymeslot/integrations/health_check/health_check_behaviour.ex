defmodule Tymeslot.Integrations.HealthCheck.HealthCheckBehaviour do
  @moduledoc """
  Behaviour for performing integration health checks.
  Production implementation is `Tymeslot.Integrations.HealthCheck`; tests use a Mox mock.
  """

  @type integration_type :: :calendar | :video

  @callback perform_single_check(integration_type(), integer()) :: :ok | {:error, any()}
end
