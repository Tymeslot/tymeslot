defmodule Tymeslot.Integrations.Video.Discovery do
  @moduledoc """
  Discovery functions for video providers.

  Wraps provider registry to list providers and retrieve defaults,
  allowing for additional filtering or mapping in the future.
  """

  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  @spec list_available_providers() :: list()
  def list_available_providers do
    ProviderRegistry.list_providers_with_metadata()
  end

  @spec default_provider() :: atom()
  def default_provider do
    ProviderRegistry.default_provider()
  end
end
