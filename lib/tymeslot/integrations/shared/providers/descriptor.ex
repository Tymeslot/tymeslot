defmodule Tymeslot.Integrations.Providers.Descriptor do
  @moduledoc """
  Unified provider descriptor used by the ProviderDirectory.

  This struct carries cross-domain provider metadata that UI and services
  can consume without reaching into provider modules directly.
  """

  @enforce_keys [:domain, :type, :display_name, :config_schema, :provider_module]
  defstruct domain: nil,
            type: nil,
            display_name: "",
            icon: nil,
            description: nil,
            button_text: nil,
            oauth: false,
            family: :other,
            capabilities: %{},
            config_schema: %{},
            provider_module: nil,
            registry_module: nil,
            setup_component: nil

  @type domain :: :calendar | :video

  @typedoc """
  How a provider connects, for grouping in the picker. `oauth` alone cannot
  answer this: a CalDAV server and a subscribed feed are both "not OAuth" but
  belong under different headings, and filing a feed under "CalDAV servers"
  tells the user something untrue about what it is.
  """
  @type family :: :oauth | :caldav | :subscription | :other

  @type t :: %__MODULE__{
          domain: domain(),
          type: atom(),
          display_name: String.t(),
          icon: any(),
          description: String.t() | nil,
          button_text: String.t() | nil,
          oauth: boolean(),
          family: family(),
          capabilities: map(),
          config_schema: map(),
          provider_module: module(),
          registry_module: module() | nil,
          setup_component: module() | nil
        }
end
