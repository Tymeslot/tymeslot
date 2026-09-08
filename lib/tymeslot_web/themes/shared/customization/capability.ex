defmodule TymeslotWeb.Themes.Shared.Customization.Capability do
  @moduledoc """
  Web-facing wrapper for the capability-based customization system.
  """

  alias Tymeslot.ThemeCustomizations.Capability

  defdelegate get_customization_options(theme_id), to: Capability
  defdelegate validate_customization(theme_id, customization_attrs), to: Capability
  defdelegate get_capability_defaults(theme_id), to: Capability
  defdelegate generate_css(theme_id, customizations), to: Capability
end
