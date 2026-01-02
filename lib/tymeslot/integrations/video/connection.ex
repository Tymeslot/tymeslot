defmodule Tymeslot.Integrations.Video.Connection do
  @moduledoc """
  Connection-related operations for video integrations.

  - Builds provider configs from DB records
  - Tests connection to providers
  - Normalizes provider identifiers
  - Emits telemetry for connection tests
  """

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @spec test_connection(pos_integer(), pos_integer()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(user_id, id) when is_integer(user_id) and is_integer(id) do
    with {:ok, integration} <- VideoIntegrationQueries.get_for_user(id, user_id) do
      start_time = System.monotonic_time(:millisecond)

      provider_atom = to_existing_atom_safe(integration.provider)
      decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
      config = build_config(provider_atom, integration, decrypted)

      result =
        case provider_atom do
          :unknown -> {:error, :unsupported_provider}
          _ -> ProviderAdapter.test_connection(provider_atom, config)
        end

      duration = System.monotonic_time(:millisecond) - start_time

      :telemetry.execute(
        [:tymeslot, :integration, :test_connection],
        %{duration: duration},
        %{provider: integration.provider, type: "video", success: match?({:ok, _}, result)}
      )

      result
    end
  end

  # Internal helpers
  defp to_existing_atom_safe(bin) when is_binary(bin) do
    String.to_existing_atom(bin)
  rescue
    ArgumentError -> :unknown
  end

  defp build_config(:mirotalk, integration, decrypted) do
    %{api_key: decrypted.api_key, base_url: integration.base_url}
  end

  defp build_config(:google_meet, integration, decrypted) do
    %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      oauth_scope: integration.oauth_scope,
      integration_id: integration.id,
      user_id: integration.user_id
    }
  end

  defp build_config(:teams, integration, decrypted) do
    %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      integration_id: integration.id,
      user_id: integration.user_id
    }
  end

  defp build_config(:custom, _integration, _decrypted), do: %{}
  defp build_config(:none, _integration, _decrypted), do: %{}
  defp build_config(_unknown, _integration, _decrypted), do: %{}
end
