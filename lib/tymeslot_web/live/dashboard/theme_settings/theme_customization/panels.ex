defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels do
  @moduledoc """
  Which dashboard panel renders an option group.

  The theme's own panels come first (`use TymeslotWeb.Themes.Core.Theme,
  option_panels: %{MyGroup => MyPanel}`), then the built-in panels for the
  shared groups (the palette, the background, and the groups under
  `theme_customizations/options/` that several themes share). A group with
  neither raises, naming its module, so a spec that gains a group without a
  panel fails `panels_test.exs` rather than showing nothing.
  """

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias Tymeslot.ThemeCustomizations.Options.Density
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.AccentPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.BackgroundPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.ColourModePanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CoverPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.DensityPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.FontPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.LogoPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.RadiusPanel
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @built_in %{
    Palette => PalettePanel,
    Background => BackgroundPanel,
    Logo => LogoPanel,
    Cover => CoverPanel,
    ColourMode => ColourModePanel,
    Accent => AccentPanel,
    Font => FontPanel,
    Radius => RadiusPanel,
    Density => DensityPanel
  }

  @doc "The panel module for `group` in the theme `theme_id`."
  @spec for_group(String.t(), OptionGroup.group()) :: module()
  def for_group(theme_id, %{module: group_module}) do
    case Map.fetch(Map.merge(@built_in, theme_panels(theme_id)), group_module) do
      {:ok, panel} ->
        panel

      :error ->
        raise ArgumentError,
              "no dashboard panel for the option group #{inspect(group_module)} of theme " <>
                "#{inspect(theme_id)}; declare one with `use TymeslotWeb.Themes.Core.Theme, " <>
                "option_panels: %{#{inspect(group_module)} => MyPanel}`"
    end
  end

  defp theme_panels(theme_id) do
    case ThemeInfo.get_theme_module(theme_id) do
      nil -> %{}
      theme -> theme.option_panels()
    end
  end
end
