defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PanelsTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias Tymeslot.ThemeCustomizations.Options.Density
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.AccentPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.BackgroundPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.ColourModePanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CoverPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.DensityPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.FontPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.LogoPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.RadiusPanel

  test "the shared groups get the built-in panels" do
    assert Panels.for_group("1", %{key: :palette, module: Palette}) == PalettePanel
    assert Panels.for_group("1", %{key: :background, module: Background}) == BackgroundPanel
    assert Panels.for_group("1", %{key: :logo, module: Logo}) == LogoPanel
    assert Panels.for_group("1", %{key: :cover, module: Cover, presets: []}) == CoverPanel
  end

  test "a group without a panel raises, naming the group's module" do
    assert_raise ArgumentError, ~r/Some\.UnknownGroup/, fn ->
      Panels.for_group("1", %{key: :mystery, module: Some.UnknownGroup})
    end
  end

  # Every catalogue theme, so a spec that gains a group without a panel fails
  # here rather than on the organiser's first visit to the dashboard.
  for {_key, theme} <- Catalog.all() do
    test "#{theme.name}: every option group has a panel with its full callback set" do
      panels =
        Enum.map(
          Specs.for_theme(unquote(theme.id)).option_groups(),
          &Panels.for_group(unquote(theme.id), &1)
        )

      assert panels != []

      assert Enum.reject(
               panels,
               &(Code.ensure_loaded?(&1) and function_exported?(&1, :render, 1) and
                   function_exported?(&1, :ui, 3) and function_exported?(&1, :handle_ui, 5) and
                   function_exported?(&1, :telemetry, 3))
             ) == []
    end
  end

  test "the accent group gets the built-in accent panel" do
    assert Panels.for_group("1", %{key: :accent, module: Accent}) == AccentPanel
  end

  test "the colour-mode group gets the built-in colour-mode panel" do
    assert Panels.for_group("1", %{key: :colour_mode, module: ColourMode}) == ColourModePanel
  end

  test "the font group gets the built-in font panel" do
    assert Panels.for_group("1", %{key: :font, module: Font}) == FontPanel
  end

  test "the radius and density groups get their built-in panels" do
    assert Panels.for_group("1", %{key: :radius, module: Radius}) == RadiusPanel
    assert Panels.for_group("1", %{key: :density, module: Density}) == DensityPanel
  end
end
