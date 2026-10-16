defmodule Tymeslot.ThemeCustomizations.OnboardingChoicesTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :onboarding
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.RhythmSpec
  alias Tymeslot.ThemeCustomizations.Tokens

  # A theme with nothing to pick in onboarding: no palette group at all.
  defmodule NoPaletteSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups, do: []
    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{}
    @impl Tymeslot.ThemeCustomizations.Spec
    def tokens(_settings, _overrides), do: %Tokens{}
  end

  # The order the wizard has always shown; the swatch row must not reshuffle.
  @onboarding_order ~w(default turquoise purple sunset ocean forest rose monochrome)

  for spec <- [QuillSpec, RhythmSpec] do
    describe "#{inspect(spec)}.onboarding_choices/0" do
      @theme_spec spec

      test "offers the palette's schemes, written through the scheme field" do
        assert %{group: :palette, field: "scheme", setting: "color_scheme", choices: choices} =
                 @theme_spec.onboarding_choices()

        assert Enum.map(choices, & &1.value) == @onboarding_order
      end

      test "names and tints each choice from its preset" do
        %{choices: choices} = @theme_spec.onboarding_choices()

        assert %{value: "purple", name: "Purple Dream", swatch: "#8b5cf6"} in choices
      end
    end
  end

  test "a spec without a palette offers nothing" do
    assert NoPaletteSpec.onboarding_choices() == nil
  end

  describe "ThemeCustomizations.onboarding_choices/1" do
    test "reads the theme's spec" do
      assert ThemeCustomizations.onboarding_choices("2") == RhythmSpec.onboarding_choices()
    end

    test "falls back to the default theme's spec for an unknown theme" do
      assert ThemeCustomizations.onboarding_choices("no-such-theme") ==
               QuillSpec.onboarding_choices()
    end
  end
end
