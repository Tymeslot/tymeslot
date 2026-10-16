defmodule Tymeslot.Test.ThemeCustomizations.GroupsSpec do
  @moduledoc """
  A test-only customisation spec declaring the shared option groups the
  lighter booking themes are built from, in their canonical order, over the
  light tones, following the visitor's OS. It is registered with no
  theme, so it is exercised through `Specs`, its generated callbacks and the
  modules that take a spec. `Tymeslot.Test.ShowcaseThemeSpec` declares the
  same groups, among the other shared ones, on a registered test theme.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Density
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.Spec

  @accents ~w(tymeslot cobalt indigo violet rose ember emerald teal graphite)

  # A custom seed still derives a light palette with a dark set, so the
  # contrast tests can walk seeds as well as tones.
  @impl Spec
  def option_groups,
    do: [
      %{
        key: :palette,
        module: Palette,
        schemes: ~w(neutral cool warm),
        seed_mode: :light,
        follow_os: true
      },
      %{key: :colour_mode, module: ColourMode, default: "auto"},
      %{key: :accent, module: Accent, presets: @accents, default: "tymeslot"},
      %{key: :font, module: Font, presets: ~w(system inter plex), default: "system"},
      %{key: :radius, module: Radius, default: "soft"},
      %{key: :density, module: Density, default: "comfortable"}
    ]

  @impl Spec
  def defaults,
    do: %{
      color_scheme: "neutral",
      colour_mode: "auto",
      accent: "tymeslot",
      font: "system",
      radius: "soft",
      density: "comfortable"
    }
end
