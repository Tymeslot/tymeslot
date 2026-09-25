defmodule Tymeslot.Integrations.Video.Discovery do
  @moduledoc """
  Discovery functions for video providers.

  Wraps the provider registry to retrieve the default provider.
  """

  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  @spec default_provider() :: atom()
  def default_provider do
    ProviderRegistry.default_provider()
  end
end
