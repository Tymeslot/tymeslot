defmodule Tymeslot.Integrations.Video.Providers.ProviderRegistry do
  @moduledoc """
  Registry for video conferencing providers.

  This module manages the available video providers and provides
  a way to get the appropriate provider implementation.
  """

  alias Tymeslot.Integrations.Video.ProviderConfig

  use Tymeslot.Integrations.Common.ProviderRegistry,
    provider_type_name: "video provider",
    default_provider: :mirotalk,
    metadata_fields: [:capabilities],
    providers: ProviderConfig.providers_map()

  @doc """
  Tests provider connection.

  This is a video-specific function that validates configuration and tests connectivity.

  `opts` carries caller context to providers that implement the optional
  `test_connection/2` callback — notably `:rate_limit_scope`, which names the
  user or integration a rate-limited connection test is charged to.
  """
  @spec test_provider_connection(atom(), map(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def test_provider_connection(provider_type, config, opts \\ []) do
    case get_provider(provider_type) do
      {:ok, module} ->
        case module.validate_config(config) do
          :ok -> run_connection_test(module, config, opts)
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp run_connection_test(module, config, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :test_connection, 2) do
      module.test_connection(config, opts)
    else
      module.test_connection(config)
    end
  end

  @doc """
  Checks if a provider type is supported (centralized).
  """
  @spec valid_provider?(atom()) :: boolean()
  defdelegate valid_provider?(provider), to: ProviderConfig

  @doc """
  Returns a list of valid provider types (includes dev providers in dev/test envs).
  """
  @spec valid_providers() :: list(atom())
  defdelegate valid_providers(), to: ProviderConfig, as: :all_providers_with_dev

  @doc """
  Validates and normalizes a provider type.
  Returns {:ok, provider} or {:error, reason}.
  """
  @spec validate_provider(atom() | String.t()) :: {:ok, atom()} | {:error, String.t()}
  defdelegate validate_provider(provider), to: ProviderConfig

  @doc """
  Returns providers that support a specific capability.
  """
  @spec providers_with_capability(atom()) :: [atom()]
  def providers_with_capability(capability) do
    list_providers_with_metadata()
    |> Enum.filter(fn provider_metadata ->
      capabilities = Map.get(provider_metadata, :capabilities, %{})
      Map.get(capabilities, capability, false)
    end)
    |> Enum.map(fn provider_metadata -> provider_metadata.type end)
  end

  @doc """
  Returns the best provider for a given set of requirements.

  This can be used to automatically select the most appropriate provider
  based on meeting requirements (e.g., number of participants, recording needs, etc.).
  """
  @spec recommend_provider(map()) :: atom()
  def recommend_provider(requirements \\ %{}) do
    # For now, just return the default provider
    # In the future, this could implement intelligent provider selection
    # based on requirements like:
    # - participant_count
    # - recording_required
    # - screen_sharing_required
    # - waiting_room_required
    # - etc.

    # Suppress unused variable warning
    _requirements = requirements
    default_provider()
  end
end
