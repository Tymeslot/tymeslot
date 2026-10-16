defmodule Tymeslot.Test.JourneyFixtureSpec do
  @moduledoc """
  Customisation spec of the journey fixture themes
  (`test/support/journey_fixtures/`): a light palette stored as a seed alone,
  following the visitor's OS, and nothing else. They exist for their
  journeys, not their options; the fixture (`"99"`) and the showcase (`"97"`)
  cover the options.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec

  @impl Spec
  def option_groups,
    do: [%{key: :palette, module: Palette, schemes: [], seed_mode: :light, follow_os: true}]

  @impl Spec
  def defaults, do: %{custom_palette_seed: "#2a6fb4"}

  # No preset schemes, so the onboarding wizard has nothing to offer.
  @impl Spec
  def onboarding_choices, do: nil
end
