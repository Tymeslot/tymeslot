defmodule Tymeslot.ThemeCustomizations.ContrastTokensTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Utils.Colour

  # WCAG 2.2 SC 1.4.3, normal-size text.
  @aa 4.5

  defp presets, do: ThemeCustomizationSchema.color_scheme_definitions()

  # Every pairing the booking page actually paints: the ink sits on both stops
  # of the primary gradient, and on the accent fill.
  defp pairs(tokens) do
    [
      {tokens.on_primary, tokens.primary_solid},
      {tokens.on_primary, tokens.primary_solid_hover},
      {tokens.on_accent, tokens.accent_solid}
    ]
  end

  defp failing_pairs(tokens) do
    Enum.reject(pairs(tokens), fn {ink, surface} ->
      Colour.contrast_ratio(ink, surface) >= @aa
    end)
  end

  describe "derive/1 across the shipped palettes" do
    test "every preset yields filled-control pairs that clear AA" do
      # Anchored so an empty preset map cannot pass this vacuously.
      assert map_size(presets()) == 8

      failures =
        Enum.flat_map(presets(), fn {id, %{colors: colors}} ->
          tokens = ContrastTokens.derive(colors)

          case failing_pairs(tokens) do
            [] -> []
            bad -> [{id, bad}]
          end
        end)

      assert failures == []
    end

    test "the default palette keeps white off the primary, which fails at 2.43:1" do
      %{colors: colors} = presets()["default"]
      tokens = ContrastTokens.derive(colors)

      # The regression this guards: white was hard-coded as the foreground.
      assert Colour.contrast_ratio("#ffffff", colors.primary) < @aa
      assert tokens.on_primary != "#ffffff"
      assert Colour.contrast_ratio(tokens.on_primary, tokens.primary_solid) >= @aa
    end

    test "a palette whose primary already carries white keeps white" do
      %{colors: colors} = presets()["monochrome"]

      assert ContrastTokens.derive(colors).on_primary == "#ffffff"
    end

    test "the surface is left alone when the chosen ink already passes on it" do
      %{colors: colors} = presets()["default"]
      tokens = ContrastTokens.derive(colors)

      # Nudging a colour that already passes would dull the organiser's brand
      # for nothing.
      assert tokens.primary_solid == colors.primary
      assert tokens.accent_solid == colors.accent
    end

    test "the surface is nudged only when the ink cannot reach AA on it as-is" do
      %{colors: colors} = presets()["turquoise"]
      tokens = ContrastTokens.derive(colors)

      assert Colour.contrast_ratio(tokens.on_primary, colors.primary) < @aa
      assert tokens.primary_solid != colors.primary
      assert Colour.contrast_ratio(tokens.on_primary, tokens.primary_solid) >= @aa
    end
  end

  describe "derive/1 for custom seeds" do
    @seeds [
      "#ff0000",
      "#ffff00",
      "#00ff88",
      "#7c3aed",
      "#000000",
      "#ffffff",
      "#808080",
      "#123456"
    ]

    test "a palette derived from any seed clears AA on its filled controls" do
      failures =
        Enum.flat_map(@seeds, fn seed ->
          %{colors: colors} = PaletteDerivation.derive_palette(seed)
          tokens = ContrastTokens.derive(colors)

          case failing_pairs(tokens) do
            [] -> []
            bad -> [{seed, bad}]
          end
        end)

      assert failures == []
    end
  end

  describe "derive/1 edge cases" do
    test "returns nil when the palette carries no primary" do
      assert ContrastTokens.derive(%{background: "#000000"}) == nil
    end

    test "returns nil when the primary is not a usable colour" do
      assert ContrastTokens.derive(%{primary: "rgba(1, 2, 3, 0.5)"}) == nil
    end

    test "returns nil for a non-map palette" do
      assert ContrastTokens.derive(nil) == nil
    end

    test "falls back to the primary when the palette has no hover or accent" do
      tokens = ContrastTokens.derive(%{primary: "#06b6d4"})

      assert tokens.primary_solid == tokens.primary_solid_hover
      assert tokens.accent_solid == tokens.primary_solid
      assert failing_pairs(tokens) == []
    end

    test "picks white when there is no background colour to weigh against it" do
      # White is the safe default rather than an arbitrary dark ink when the
      # palette offers no in-family alternative.
      assert ContrastTokens.derive(%{primary: "#7c3aed"}).on_primary == "#ffffff"
    end
  end
end
