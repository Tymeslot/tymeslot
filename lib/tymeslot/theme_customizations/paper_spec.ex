defmodule Tymeslot.ThemeCustomizations.PaperSpec do
  @moduledoc """
  Customisation spec of the Paper theme: a neutral tone with one accent
  colour, a colour mode (light, dark, or the visitor's own), a font, a
  corner style and a logo. Paper has no background option: the tone's
  canvas is the page.

  The groups are the shared ones, in the canonical order, so the generated
  `changeset/2`, `asset_fields/0` and `tokens/2` stand: the palette lays out
  the tone's light set and its dark set (`follow_os: true`), the colour mode
  picks between them, and the accent then replaces the primary family in
  whichever sets remain, fitted to each set's card; the font and radius add
  their variables and the logo its media.

  Onboarding offers the accents rather than the tones. The three tones share
  one primary and differ only in their greys, so their swatches would be
  three identical circles, while the accent is the colour a Paper page is
  recognised by.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Specs

  @tones ~w(neutral cool warm)
  @accents ~w(tymeslot cobalt indigo violet rose ember emerald teal graphite)
  @fonts ~w(system inter plex)

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette, schemes: @tones, seed_mode: :light, follow_os: true},
      %{key: :colour_mode, module: ColourMode, default: "auto"},
      %{key: :accent, module: Accent, presets: @accents, default: "tymeslot"},
      %{key: :font, module: Font, presets: @fonts, default: "system"},
      %{key: :radius, module: Radius, default: "soft"},
      %{key: :logo, module: Logo}
    ]

  @impl Spec
  def defaults,
    do: %{
      color_scheme: "neutral",
      colour_mode: "auto",
      accent: "tymeslot",
      font: "system",
      radius: "soft"
    }

  @impl Spec
  def onboarding_choices do
    group = Specs.group(__MODULE__, Accent)

    %{
      group: group.key,
      field: "preset",
      setting: "accent",
      choices:
        for {id, %{name: name, color: colour}} <- Accent.presets(group) do
          %{value: id, name: name, swatch: colour}
        end
    }
  end
end
