defmodule Tymeslot.ThemeCustomizations.FolioSpec do
  @moduledoc """
  Customisation spec for Folio: the organiser's page, with a cover image, a
  serif pairing and one of six editorial schemes.

  The shared groups in the canonical order: the palette over Folio's schemes,
  each in a fixed mode (a custom seed derives a light palette, and the page
  never follows the visitor's OS), the font pairings, the corner radius and
  the cover. There is no background group: the cover is the page's hero and
  the scheme's canvas is its ground. `changeset/2`, `asset_fields/0`,
  `tokens/2` and `onboarding_choices/0` are the generated ones.
  """

  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.Spec

  # In the order the onboarding wizard shows them: the four light schemes,
  # then the two dark ones.
  @schemes ~w(ivory sage harbour blush dusk ink)
  @fonts ~w(classic literary editorial quiet)
  @covers ~w(elegant-still-life artistic-studio ocean-sunset rustic-farmhouse botanical studio-light paper-texture)

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette, schemes: @schemes, seed_mode: :light},
      %{key: :font, module: Font, presets: @fonts, default: "classic"},
      %{key: :radius, module: Radius, default: "soft"},
      %{key: :cover, module: Cover, presets: @covers, default: "elegant-still-life"}
    ]

  @impl Spec
  def defaults,
    do: %{
      color_scheme: "ivory",
      font: "classic",
      radius: "soft",
      cover_value: "elegant-still-life"
    }
end
