defmodule Tymeslot.Integrations.Providers.DescriptorBehaviour do
  @moduledoc """
  Behaviour for provider metadata/descriptor. Providers may implement
  these callbacks to supply richer metadata. The directory will fall
  back to sensible defaults if callbacks are not implemented.

  There is deliberately no `oauth?/0` callback: how a provider connects is
  declared once, in the family table of its domain's `ProviderConfig`
  (see `Tymeslot.Integrations.Providers.Families`). A per-provider override
  here would be a second answer to the same question, free to contradict the
  table the picker groups by.
  """

  @callback provider_type() :: atom()
  @callback display_name() :: String.t()
  @callback config_schema() :: map()
  @callback capabilities() :: map()
  @callback setup_component() :: module() | nil
end
