defmodule Tymeslot.Test.FixtureThemeSpecTest do
  @moduledoc """
  The fixture theme's spec (`test/support/fixture_theme/`) works with nothing
  but the shared `Spec` machinery: a palette with no presets, derived light,
  no background, a group of its own with a choice, an upload and a media
  entry, and a second with two videos. None of the shared modules knows it exists.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.Test.FixtureThemeSpec
  alias Tymeslot.Test.FixtureThemeSpec.Clips
  alias Tymeslot.Test.FixtureThemeSpec.Emblem
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Utils.Colour

  defp defaults, do: Map.new(FixtureThemeSpec.defaults(), fn {k, v} -> {Atom.to_string(k), v} end)

  defp validate(attrs) do
    {%{}, Specs.setting_types(FixtureThemeSpec)}
    |> Changeset.change()
    |> FixtureThemeSpec.changeset(attrs)
  end

  describe "settings" do
    test "are the palette's, the emblem's and the clips', and nothing of the background's" do
      assert Specs.setting_types(FixtureThemeSpec) ==
               Palette.types() |> Map.merge(Emblem.types()) |> Map.merge(Clips.types())

      refute Map.has_key?(Specs.setting_types(FixtureThemeSpec), :background_type)
    end

    test "the defaults pass the generated changeset" do
      assert validate(defaults()).valid?
    end

    test "the generated changeset runs the emblem group's own validation" do
      changeset = validate(Map.put(defaults(), "fixture_emblem_shape", "oval"))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :fixture_emblem_shape)
    end

    test "the generated asset fields are the emblem's image, the two clips and the captions" do
      assert FixtureThemeSpec.asset_fields() == [
               fixture_emblem_path: :image,
               fixture_intro_clip_path: :video,
               fixture_outro_clip_path: :video,
               fixture_intro_captions_path: :captions
             ]
    end

    test "store a seed-only palette: no scheme name beside the seed" do
      refute Map.has_key?(FixtureThemeSpec.defaults(), :color_scheme)
      assert FixtureThemeSpec.defaults().custom_palette_seed
    end

    test "offers no onboarding choice, having no preset schemes" do
      assert FixtureThemeSpec.onboarding_choices() == nil
    end
  end

  describe "tokens/2" do
    test "write the whole palette for the seed alone, through the context's read" do
      %Tokens{vars: vars, dark_vars: dark_vars} = ThemeCustomizations.tokens("99", nil)

      for name <-
            ~w(--theme-primary --theme-canvas --theme-surface --theme-text --theme-on-primary) do
        assert vars[name], "#{name} missing from the seed-only palette"
      end

      assert dark_vars["--theme-canvas"]
    end

    test "derive a light palette from the stored seed" do
      %Tokens{vars: vars} = FixtureThemeSpec.tokens(defaults(), %{})

      assert Colour.relative_luminance(vars["--theme-canvas"]) > 0.5
      assert Colour.relative_luminance(vars["--theme-text"]) < 0.2
    end

    test "hand the seed's dark derivation to the dark block, since the group follows the OS" do
      %Tokens{dark_vars: dark_vars} = FixtureThemeSpec.tokens(defaults(), %{})

      assert Colour.relative_luminance(dark_vars["--theme-canvas"]) < 0.2
    end

    test "carry the emblem shape as a variable of the theme's own" do
      assert %Tokens{vars: %{"--fixture-emblem-radius" => "999px"}} =
               FixtureThemeSpec.tokens(defaults(), %{})

      assert %Tokens{vars: %{"--fixture-emblem-radius" => "0"}} =
               FixtureThemeSpec.tokens(Map.put(defaults(), "fixture_emblem_shape", "square"), %{})
    end

    test "carry an uploaded emblem in media under a key of the group's own, and no background" do
      settings = Map.put(defaults(), "fixture_emblem_path", "themes/7/99/images/emblem.png")

      assert FixtureThemeSpec.tokens(settings, %{}).media == %{
               emblem: "/uploads/themes/7/99/images/emblem.png"
             }

      assert FixtureThemeSpec.tokens(defaults(), %{}).media == %{}
    end
  end

  describe "the emblem group" do
    test "turns a shape choice into its setting, and refuses any other field" do
      group = Specs.group(FixtureThemeSpec, Emblem)

      assert Emblem.changes("shape", "square", group) ==
               {:ok, %{"fixture_emblem_shape" => "square"}}

      assert Emblem.changes("colour", "red", group) == :error
    end

    test "saves an upload to its own setting only" do
      group = Specs.group(FixtureThemeSpec, Emblem)

      assert Emblem.upload_changes(:fixture_emblem_path, "themes/7/99/images/e.png", group) ==
               %{"fixture_emblem_path" => "themes/7/99/images/e.png"}
    end
  end
end
