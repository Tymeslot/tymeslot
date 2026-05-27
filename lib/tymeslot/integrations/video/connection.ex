defmodule Tymeslot.Integrations.Video.Connection do
  @moduledoc """
  Connection-related operations for video integrations.

  - Tests connection to providers
  - Emits telemetry for connection tests

  Provider-specific config shapes live in each provider module's `build_config/3`.
  """

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @spec test_connection(pos_integer(), pos_integer()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(user_id, id) when is_integer(user_id) and is_integer(id) do
    case Video.fetch_integration_for_user(id, user_id) do
      {:ok, integration} ->
        run_connection_test(integration)

      {:error, :not_found} = error ->
        error
    end
  end

  defp run_connection_test(integration) do
    start_time = System.monotonic_time(:millisecond)
    result = do_test_connection(integration)

    :telemetry.execute(
      [:tymeslot, :integration, :test_connection],
      %{duration: System.monotonic_time(:millisecond) - start_time},
      %{provider: integration.provider, type: "video", success: match?({:ok, _}, result)}
    )

    result
  end

  defp do_test_connection(integration) do
    with {:ok, provider_atom} <- ProviderConfig.parse_known(integration.provider),
         module when module != nil <- ProviderConfig.get_provider_module(provider_atom) do
      decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
      config = module.build_config(integration, decrypted, [])
      ProviderAdapter.test_connection(provider_atom, config)
    else
      _other -> {:error, :unsupported_provider}
    end
  end
end
