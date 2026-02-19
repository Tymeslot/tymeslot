defmodule Tymeslot.Integrations.HealthCheck.ResponseHandler do
  @moduledoc """
  Domain: Failure Response & Recovery Actions

  Takes appropriate actions when integrations change health status.
  Handles alert notifications and recovery logging. Integrations are
  never auto-deactivated; health status is surfaced without touching
  the `is_active` flag.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.HealthCheck.Monitor

  @type integration_type :: :calendar | :video

  @doc """
  Handles a health status transition by taking appropriate action.
  """
  @spec handle_transition(integration_type(), map(), Monitor.transition()) :: :ok
  def handle_transition(_type, _integration, {:no_change, _old_status, _new_status}), do: :ok

  def handle_transition(type, integration, {:initial_failure, nil, :unhealthy}) do
    Logger.error("Integration health check failed on first attempt",
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    send_failure_alert(type, integration, "Initial health check failure")
  end

  def handle_transition(type, integration, {:became_unhealthy, old_status, :unhealthy}) do
    Logger.error("Integration health critical (was #{inspect(old_status)})",
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    send_failure_alert(type, integration, "Health check failures exceeded threshold")
  end

  def handle_transition(type, integration, {:became_healthy, :unhealthy, :healthy}) do
    Logger.info("Integration health recovered",
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    send_recovery_alert(type, integration)
  end

  def handle_transition(type, integration, {:became_degraded, :healthy, :degraded}) do
    Logger.warning("Integration health degraded",
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    :ok
  end

  # Private Functions

  defp send_failure_alert(type, integration, reason) do
    case AdminAlerts.send_alert(
           :integration_health_failure,
           %{
             type: type,
             integration_id: integration.id,
             provider: integration.provider,
             user_id: integration.user_id,
             reason: reason
           },
           level: :error
         ) do
      :ok ->
        :ok

      {:error, alert_reason} ->
        Logger.error("Failed to send integration failure alert",
          type: type,
          integration_id: integration.id,
          alert_error: alert_reason
        )
    end
  end

  defp send_recovery_alert(type, integration) do
    case AdminAlerts.send_alert(
           :integration_health_recovery,
           %{
             type: type,
             integration_id: integration.id,
             provider: integration.provider,
             user_id: integration.user_id
           },
           level: :info
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send integration recovery alert",
          type: type,
          integration_id: integration.id,
          alert_error: reason
        )
    end
  end

end
