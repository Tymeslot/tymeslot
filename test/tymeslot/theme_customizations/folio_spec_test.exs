defmodule Tymeslot.ThemeCustomizations.FolioSpecTest do
  @moduledoc """
  Folio's customisation spec: the shared palette, font, radius and cover
  groups in the canonical order, over Folio's six fixed-mode schemes, driven
  through `Specs` and the spec's generated callbacks.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.FolioSpec
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Utils.Colour

  @schemes ~w(ivory sage harbour blush dusk ink)

  defp defaults, do: Map.new(FolioSpec.defaults(), fn {k, v} -> {Atom.to_string(k), v} end)

  defp with_setting(key, value), do: Map.put(defaults(), key, value)

  defp validate(attrs) do
    {%{}, Specs.setting_types(FolioSpec)}
    |> Changeset.change()
    |> FolioSpec.changeset(attrs)
  end

  describe "groups" do
    test "are the palette, font, radius and cover, in the canonical order" do
      assert Enum.map(FolioSpec.option_groups(), & &1.key) == [:palette, :font, :radius, :cover]
    end

    test "offer Folio's schemes, pairings and covers" do
      [palette, font, radius, cover] = FolioSpec.option_groups()

      assert palette.schemes == @schemes
      assert palette.seed_mode == :light
      refute palette[:follow_os]
      assert font.presets == ~w(classic literary editorial quiet)
      assert font.default == "classic"
      assert radius.default == "soft"

      assert cover.presets ==
               ~w(elegant-still-life artistic-studio ocean-sunset rustic-farmhouse botanical studio-light paper-texture)

      assert cover.default == "elegant-still-life"
    end

    test "have no background, so the page is the palette's canvas" do
      assert Specs.background_kinds(FolioSpec) == []
      refute Map.has_key?(FolioSpec.tokens(defaults(), %{}).media, :background)
    end
  end

  describe "defaults" do
    test "are what an empty row reads as, and pass the changeset" do
      assert Specs.settings(FolioSpec, %{}) == defaults()
      assert validate(defaults()).valid?
    end
  end

  describe "palette" do
    test "each scheme is the page's canvas, card, text and primary, with no dark set" do
      failures =
        for id <- @schemes,
            colors = Presets.find_preset_by_id(:color_scheme, id).colors,
            %Tokens{vars: vars, dark_vars: dark_vars} =
              FolioSpec.tokens(with_setting("color_scheme", id), %{}),
            vars["--theme-canvas"] != colors.background or
              vars["--theme-surface"] != colors.surface or
              vars["--theme-text"] != colors.text or
              vars["--theme-primary"] != colors.primary or
              dark_vars != %{},
            do: id

      assert failures == []
    end

    test "every scheme's filled controls clear 4.5:1" do
      failures =
        for id <- @schemes,
            %Tokens{vars: vars} = FolioSpec.tokens(with_setting("color_scheme", id), %{}),
            Colour.contrast_ratio(vars["--theme-on-primary"], vars["--theme-primary-solid"]) < 4.5,
            do: id

      assert failures == []
    end

    test "refuses a scheme of another theme" do
      changeset = validate(with_setting("color_scheme", "purple"))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :color_scheme)
    end

    test "a custom seed derives a light palette whose primary reads on the card" do
      %Tokens{vars: vars, dark_vars: dark_vars} =
        FolioSpec.tokens(Map.put(defaults(), "custom_palette_seed", "#f4c430"), %{})

      assert Colour.relative_luminance(vars["--theme-canvas"]) > 0.8
      assert Colour.contrast_ratio(vars["--theme-primary"], vars["--theme-surface"]) >= 4.5
      assert dark_vars == %{}
    end

    test "a page view's primary colour replaces the scheme's, fitted for filled controls" do
      %Tokens{vars: vars} = FolioSpec.tokens(defaults(), %{primary_color: "#e11d48"})

      assert vars["--theme-primary"] == "#e11d48"

      assert Colour.contrast_ratio(vars["--theme-on-primary"], vars["--theme-primary-solid"]) >=
               4.5

      assert vars["--theme-canvas"] == "#faf7f2"
    end
  end

  describe "font" do
    test "a pairing sets the body and heading stacks, never a family name" do
      %Tokens{vars: vars} = FolioSpec.tokens(with_setting("font", "literary"), %{})

      assert vars["--theme-font-family"] == "var(--font-stack-literary)"
      assert vars["--theme-font-heading"] == "var(--font-heading-literary)"
    end

    test "refuses a font Folio does not offer" do
      refute validate(with_setting("font", "inter")).valid?
    end
  end

  describe "radius" do
    test "sets the control and card radii" do
      %Tokens{vars: vars} = FolioSpec.tokens(with_setting("radius", "round"), %{})

      assert vars["--radius-control"] == "999px"
      assert vars["--radius-card"] == "20px"
    end
  end

  describe "cover" do
    test "defaults to the still life" do
      assert FolioSpec.tokens(defaults(), %{}).media.cover == %{
               src: Presets.find_preset_by_id(:cover, "elegant-still-life").src,
               preset: "elegant-still-life"
             }
    end

    test "offers the covers of its own" do
      for id <- ~w(botanical studio-light paper-texture) do
        assert %{preset: ^id, src: "/images/themes/covers/" <> _file} =
                 FolioSpec.tokens(with_setting("cover_value", id), %{}).media.cover
      end
    end

    test "refuses a cover it does not offer" do
      refute validate(with_setting("cover_value", "space-satellite")).valid?
    end
  end

  describe "onboarding" do
    test "offers the six schemes in order, each swatch its primary" do
      %{group: :palette, field: "scheme", setting: "color_scheme", choices: choices} =
        FolioSpec.onboarding_choices()

      assert Enum.map(choices, & &1.value) == @schemes

      assert Enum.map(choices, & &1.swatch) ==
               Enum.map(@schemes, &Presets.find_preset_by_id(:color_scheme, &1).colors.primary)
    end
  end

  describe "the contrast rule Folio relies on" do
    test "the default primary already reads on the default card" do
      %Tokens{vars: vars} = FolioSpec.tokens(defaults(), %{})

      assert ContrastTokens.fit_text(vars["--theme-primary"], vars["--theme-surface"]) ==
               vars["--theme-primary"]
    end
  end
end
