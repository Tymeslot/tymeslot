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

  # This is a video-specific function that just talks to the network — no
  # validation and no rate limiting here. It is public only so
  # `ProviderAdapter.test_connection/2` (its one legitimate caller) can reach
  # it across module boundaries; `@doc false` keeps it out of published docs
  # so it doesn't read as a general-purpose entry point. Every other route to
  # a connection test goes through `Tymeslot.Integrations.Video.Connection`,
  # which validates the config structurally and decides whether and to whom
  # the test is rate-limited before this ever runs.
  @doc false
  @spec test_provider_connection(atom(), map()) :: :ok | {:ok, term()} | {:error, term()}
  def test_provider_connection(provider_type, config) do
    case get_provider(provider_type) do
      {:ok, module} -> module.perform_connection_test(config)
      {:error, _reason} = error -> error
    end
  end

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
end
