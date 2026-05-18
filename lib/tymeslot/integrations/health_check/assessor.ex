defmodule Tymeslot.Integrations.HealthCheck.Assessor do
  @moduledoc """
  Domain: Integration Health Testing

  Executes health checks for different integration types and providers.
  Knows how to test calendar and video integrations, build provider-specific
  configurations, and record telemetry.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Diagnostics
  alias Tymeslot.Integrations.HealthCheck.ProviderHelpers
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
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
    provider_atom = ProviderHelpers.safe_to_existing_atom(integration.provider)

    case provider_atom do
      nil ->
        {:error, :unsupported_provider}

      provider ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
        config = build_video_config(provider, integration, decrypted)
        test_video_provider(provider, config)
    end
  end

  # Private Functions

  defp test_video_provider(provider_atom, config) do
    ProviderAdapter.test_connection(provider_atom, config)
  rescue
    _e in [UndefinedFunctionError] -> {:error, :module_unavailable}
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp build_video_config(:mirotalk, integration, decrypted) do
    %{api_key: decrypted.api_key, base_url: integration.base_url}
  end

  defp build_video_config(:google_meet, integration, decrypted) do
    %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      oauth_scope: integration.oauth_scope,
      integration_id: integration.id,
      user_id: integration.user_id
    }
  end

  defp build_video_config(:teams, integration, decrypted) do
    %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      integration_id: integration.id,
      user_id: integration.user_id
    }
  end

  defp build_video_config(:custom, integration, _decrypted) do
    %{custom_meeting_url: integration.custom_meeting_url}
  end

  defp build_video_config(_other, _integration, _decrypted), do: %{}

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
