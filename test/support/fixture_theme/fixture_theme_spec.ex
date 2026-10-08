defmodule Tymeslot.Test.FixtureThemeSpec do
  @moduledoc """
  Customisation spec of the test-only fixture theme
  (`test/support/fixture_theme/`, registered by `config/test.exs`).

  A light palette with no preset schemes (a custom seed, derived light and
  following the visitor's OS, stored as the seed alone), no background, and
  two groups of its own: `Emblem` (a shape and an image) and `Clips` (two
  videos, so the theme offers more than one). `changeset/2` and
  `asset_fields/0` are the ones `use Spec` generates, and `tokens/2` starts
  from the generated default (`Specs.tokens/3`); nothing here restates a
  shared rule.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.Test.FixtureThemeSpec.Clips
  alias Tymeslot.Test.FixtureThemeSpec.Emblem
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Specs

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette, schemes: [], seed_mode: :light, follow_os: true},
      %{key: :emblem, module: Emblem, choices: ["round", "square"]},
      %{key: :clips, module: Clips}
    ]

  # A seed-only palette: the group offers no preset schemes, so the stored
  # seed is the palette and no scheme name is stored beside it.
  @impl Spec
  def defaults, do: %{custom_palette_seed: "#b4532a", fixture_emblem_shape: "round"}

  # The standard tokens plus the emblem's own variable.
  @impl Spec
  def tokens(settings, overrides) do
    tokens = Specs.tokens(__MODULE__, settings, overrides)
    emblem = Emblem.vars(settings, Specs.group(__MODULE__, Emblem))
    %{tokens | vars: Map.merge(tokens.vars, emblem)}
  end

  # No preset schemes, so the onboarding wizard has nothing to offer.
  @impl Spec
  def onboarding_choices, do: nil
end
