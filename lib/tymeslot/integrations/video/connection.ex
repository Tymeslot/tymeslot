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

  @doc """
  Runs a connection test against an already-loaded integration struct.

  Resolves the provider module from the single source of truth (`ProviderConfig`),
  builds the provider config via its `build_config/3` callback, and delegates to
  the provider's connection test. This is the one canonical connection-test path:
  the user-facing `test_connection/2` wraps it with loading and telemetry, and the
  background health check (`HealthCheck.Assessor`) calls it directly, so both
  exercise an identical pipeline and stay in lockstep as providers change.

  `:scope` says which of the two is calling. It decides the rate-limit bucket a
  provider charges the test to, and keeping the two apart is the point: a busy
  instance's scheduled probing must never be able to exhaust the budget a real
  user's "Test connection" button draws from.
  """
  @type scope :: :interactive | :background

  @spec test_integration(VideoIntegrationSchema.t(), keyword()) ::
          {:ok, String.t()} | {:error, any()}
  def test_integration(%VideoIntegrationSchema{} = integration, opts \\ []) do
    with {:ok, provider_atom} <- ProviderConfig.parse_known(integration.provider),
         module when module != nil <- ProviderConfig.get_provider_module(provider_atom) do
      decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
      config = module.build_config(integration, decrypted, [])

      ProviderAdapter.test_connection(provider_atom, config,
        rate_limit_scope: rate_limit_scope(integration, Keyword.get(opts, :scope, :interactive))
      )
    else
      _other -> {:error, :unsupported_provider}
    end
  end

  defp rate_limit_scope(integration, :interactive), do: {:user, integration.user_id}
  defp rate_limit_scope(integration, :background), do: {:integration, integration.id}

  defp run_connection_test(integration) do
    start_time = System.monotonic_time(:millisecond)
    result = test_integration(integration)

    :telemetry.execute(
      [:tymeslot, :integration, :test_connection],
      %{duration: System.monotonic_time(:millisecond) - start_time},
      %{provider: integration.provider, type: "video", success: match?({:ok, _}, result)}
    )

    result
  end
end
