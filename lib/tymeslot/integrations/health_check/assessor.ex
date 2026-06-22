defmodule Tymeslot.Integrations.HealthCheck.Assessor do
  @moduledoc """
  Domain: Integration Health Testing

  Executes health checks for different integration types and providers.
  Knows how to test calendar and video integrations, build provider-specific
  configurations, and record telemetry.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Diagnostics
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @type integration_type :: :calendar | :video
  @type check_result :: {:ok, any()} | {:error, any()}
  @type integration ::
          CalendarIntegrationSchema.t() | VideoIntegrationSchema.t()

  @doc """
  Performs a health check for an integration and records telemetry.
  Returns the result and duration.
  """
  @spec assess(integration_type(), integration()) :: {check_result(), non_neg_integer()}
  def assess(type, integration) do
    start_time = System.monotonic_time(:millisecond)
    result = test_integration(type, integration)
    duration = System.monotonic_time(:millisecond) - start_time

    record_telemetry(type, integration, result, duration)

    {result, duration}
  end

  @doc """
  Tests the health of an integration by attempting a connection.
  """
  @spec test_integration(integration_type(), integration()) :: check_result()
  def test_integration(:calendar, integration) do
    decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)
    Diagnostics.test_connection(decrypted)
  rescue
    _e in [UndefinedFunctionError] -> {:error, :module_unavailable}
    e -> {:error, {:exception, Exception.message(e)}}
  end

  def test_integration(:video, integration) do
    Connection.test_integration(integration)
  rescue
    _e in [UndefinedFunctionError] -> {:error, :module_unavailable}
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Private Functions

  defp record_telemetry(type, integration, result, duration) do
    :telemetry.execute(
      [:tymeslot, :integration, :health_check],
      %{duration: duration},
      %{
        type: type,
        provider: integration.provider,
        integration_id: integration.id,
        user_id: integration.user_id,
        success: match?({:ok, _}, result)
      }
    )
  end
end
