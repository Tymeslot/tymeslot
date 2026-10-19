defmodule TymeslotWeb.Dashboard.CalendarSettings.Helpers do
  @moduledoc """
  Helper functions for calendar settings dashboard.
  """
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.DisplayHelpers

  @spec format_provider_name(String.t() | atom()) :: String.t()
  def format_provider_name(provider) do
    DisplayHelpers.format_provider_display_name(provider)
  end

  @spec needs_scope_upgrade?(map()) :: boolean()
  def needs_scope_upgrade?(integration) do
    Calendar.needs_scope_upgrade?(integration)
  end

  @doc """
  The class of a card action that carries a text label as well as an icon,
  so cannot be `icon_button/1`: it takes the icon button's tile look (the
  `.icon-button` colour rules set no size or padding) and the small action
  button's size, so it sits level with the icon buttons in the card's footer
  and keeps its label at every width.
  """
  @spec tile_class(atom()) :: [String.t()]
  def tile_class(variant),
    do: ["icon-button", "icon-button--#{variant}", "gap-1.5 px-3 py-1.5 text-token-sm font-bold"]
end
