defmodule Tymeslot.Integrations.Providers.DescriptorBehaviour do
  @moduledoc """
  Behaviour for provider metadata/descriptor. Providers may implement
  these callbacks to supply richer metadata. The directory will fall
  back to sensible defaults if callbacks are not implemented.
  """

  @callback provider_type() :: atom()
  @callback display_name() :: String.t()
  @callback config_schema() :: map()
  @callback capabilities() :: map()
  @callback oauth?() :: boolean()
  @callback setup_component() :: module() | nil
end
