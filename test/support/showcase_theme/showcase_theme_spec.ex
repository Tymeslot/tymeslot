defmodule Tymeslot.Test.ShowcaseThemeSpec do
  @moduledoc """
  Customisation spec of the test-only showcase theme
  (`test/support/showcase_theme/`, registered by `config/test.exs`): every
  shared option group no shipped theme offers yet, in the canonical group
  order, over the light tones, following the visitor's OS, with Quill's
  background last. It exists so that each shared group, and all of them
  together, is reachable through the real dashboard and booking page. The
  generated `changeset/2`, `asset_fields/0` and `tokens/2` stand.
  `Tymeslot.Test.ThemeCustomizations.GroupsSpec` declares the same colour,
  font and shape groups as a spec of no theme, for the unit tests.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias Tymeslot.ThemeCustomizations.Options.Density
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Specs

  @accents ~w(tymeslot cobalt indigo violet rose ember emerald teal graphite)
  # A subset of the fonts, so that a font the group does not offer exists.
  @fonts ~w(system inter plex editorial)
  @covers ~w(elegant-still-life artistic-studio ocean-sunset rustic-farmhouse)

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
      %{key: :font, module: Font, presets: @fonts, default: "system"},
      %{key: :radius, module: Radius, default: "soft"},
      %{key: :density, module: Density, default: "comfortable"},
      %{key: :logo, module: Logo},
      %{key: :cover, module: Cover, presets: @covers, default: "elegant-still-life"},
      Specs.group(QuillSpec, Background)
    ]

  @impl Spec
  def defaults,
    do:
      QuillSpec.defaults()
      |> Map.take([:background_type, :background_value])
      |> Map.merge(%{
        color_scheme: "neutral",
        colour_mode: "auto",
        accent: "tymeslot",
        font: "system",
        radius: "soft",
        density: "comfortable",
        cover_value: "elegant-still-life"
      })

  # The tones are chosen with the theme, not in onboarding.
  @impl Spec
  def onboarding_choices, do: nil
end
