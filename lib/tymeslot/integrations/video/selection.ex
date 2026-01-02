defmodule Tymeslot.Integrations.Video.Selection do
  @moduledoc """
  Selection helpers for choosing and validating video providers.

  Provides convenience functions around ProviderConfig for higher-level flows.
  """

  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  @spec providers_with_capability(atom()) :: [atom()]
  def providers_with_capability(capability),
    do: ProviderRegistry.providers_with_capability(capability)

  @spec recommend_provider(map()) :: atom()
  def recommend_provider(requirements \\ %{}),
    do: ProviderRegistry.recommend_provider(requirements)
end
