defmodule Tymeslot.ThemeCustomizationsPaletteDerivationTest do
  use ExUnit.Case, async: true
  @moduletag :themes

  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.Utils.Colour

  describe "derive_palette/1" do
    test "returns nil for nil input" do
      assert PaletteDerivation.derive_palette(nil) == nil
    end

    test "returns nil for invalid hex" do
      assert PaletteDerivation.derive_palette("not-a-hex") == nil
      assert PaletteDerivation.derive_palette("#zzzzzz") == nil
      assert PaletteDerivation.derive_palette("#1234") == nil
    end

    test "returns the same shape as a static preset" do
      %{name: name, colors: colors} = PaletteDerivation.derive_palette("#06b6d4")

      assert name == "Custom"

      assert Enum.sort(Map.keys(colors)) ==
               [
                 :accent,
                 :background,
                 :primary,
                 :primary_hover,
                 :secondary,
                 :surface,
                 :text,
                 :text_secondary
               ]
    end

    test "uses the seed as primary, lowercased" do
      assert %{colors: %{primary: "#06b6d4"}} = PaletteDerivation.derive_palette("#06B6D4")
    end

    test "all hex tokens are 6-character lowercase hex strings" do
      %{colors: colors} = PaletteDerivation.derive_palette("#ff6b35")

      Enum.each(
        [:primary, :primary_hover, :secondary, :accent, :background, :text, :text_secondary],
        fn key ->
          value = Map.fetch!(colors, key)

          assert String.match?(value, ~r/^#[0-9a-f]{6}$/),
                 "expected lowercase hex for #{key}, got #{inspect(value)}"
        end
      )
    end

    test "surface is an rgba string at 0.5 alpha" do
      %{colors: %{surface: surface}} = PaletteDerivation.derive_palette("#06b6d4")
      assert String.match?(surface, ~r/^rgba\(\d+, \d+, \d+, 0\.5\)$/)
    end

    test "primary_hover is darker than primary" do
      %{colors: %{primary: primary, primary_hover: hover}} =
        PaletteDerivation.derive_palette("#06b6d4")

      assert luminance(hover) < luminance(primary)
    end

    test "background is a dark colour regardless of seed" do
      Enum.each(["#06b6d4", "#ff6b35", "#8b5cf6", "#ffffff", "#000000"], fn seed ->
        %{colors: %{background: bg}} = PaletteDerivation.derive_palette(seed)
        assert luminance(bg) < 0.20, "expected dark background for seed #{seed}, got #{bg}"
      end)
    end

    test "text is a light colour regardless of seed" do
      Enum.each(["#06b6d4", "#ff6b35", "#8b5cf6", "#ffffff", "#000000"], fn seed ->
        %{colors: %{text: text}} = PaletteDerivation.derive_palette(seed)
        assert luminance(text) > 0.80, "expected light text for seed #{seed}, got #{text}"
      end)
    end

    test "accepts 3-character hex shorthand" do
      assert %{colors: %{primary: primary}} = PaletteDerivation.derive_palette("#abc")
      assert primary == "#aabbcc"
    end
  end

  describe "derive_palette/2" do
    @seeds ~w(#ff0000 #ffff00 #00ff88 #22d3ee #7c3aed #000000 #ffffff #808080 #123456 #ff6b35)

    test "derives a dark palette unless told otherwise" do
      for seed <- @seeds do
        assert %{mode: :dark} = palette = PaletteDerivation.derive_palette(seed)
        assert PaletteDerivation.derive_palette(seed, :dark) == palette
        refute Map.has_key?(palette, :dark_colors)
      end
    end

    test "a light palette has the preset shape" do
      %{name: "Custom", mode: :light, colors: colors, dark_colors: dark_colors} =
        PaletteDerivation.derive_palette("#FF6B35", :light)

      keys = ~w(accent background primary primary_hover secondary surface text text_secondary)a

      assert Enum.sort(Map.keys(colors)) == keys
      assert Enum.sort(Map.keys(dark_colors)) == keys

      for {key, value} <- colors do
        assert value =~ ~r/^#[0-9a-f]{6}$/, "expected lowercase hex for #{key}, got #{value}"
      end
    end

    test "a light palette keeps a seed that already reads on its surface as its primary" do
      assert PaletteDerivation.derive_palette("#123456", :light).colors.primary == "#123456"
      assert PaletteDerivation.derive_palette("#7c3aed", :light).colors.primary == "#7c3aed"
    end

    test "a light palette darkens a seed too bright to read on its surface, and its hover follows" do
      %{colors: colors} = PaletteDerivation.derive_palette("#FF6B35", :light)

      assert colors.primary == "#d83a00"
      assert colors.primary_hover == "#af2f00"
    end

    test "a light palette's primary reads on its surface and its secondary and accent show on its ground, whatever the seed" do
      failures =
        for seed <- @seeds,
            %{colors: c} = PaletteDerivation.derive_palette(seed, :light),
            problem <- [
              Colour.contrast_ratio(c.primary, c.surface) >= 4.5 || :primary_on_surface,
              Colour.contrast_ratio(c.secondary, c.background) >= 3.0 || :secondary_on_background,
              Colour.contrast_ratio(c.accent, c.background) >= 3.0 || :accent_on_background
            ],
            problem != true,
            do: {seed, problem}

      assert failures == []
    end

    test "a light palette puts legible dark text on a near-white ground, whatever the seed" do
      failures =
        for seed <- @seeds,
            %{colors: c} = PaletteDerivation.derive_palette(seed, :light),
            problem <- [
              Colour.relative_luminance(c.background) > 0.85 || :background_not_light,
              Colour.contrast_ratio(c.text, c.background) >= 7.0 || :text,
              Colour.contrast_ratio(c.text_secondary, c.background) >= 4.5 ||
                :text_secondary_on_background,
              Colour.contrast_ratio(c.text_secondary, c.surface) >= 4.5 ||
                :text_secondary_on_surface
            ],
            problem != true,
            do: {seed, problem}

      assert failures == []
    end

    test "a light palette's ground sits visibly below its card surface, whatever the seed" do
      for seed <- @seeds do
        %{colors: c} = PaletteDerivation.derive_palette(seed, :light)
        {_h, _s, ground_l} = Colour.hex_to_hsl(c.background)
        {_h, _s, surface_l} = Colour.hex_to_hsl(c.surface)

        assert surface_l - ground_l >= 0.03,
               "expected the ground at least 3 points below the surface for #{seed}"
      end
    end

    test "a light palette's dark counterpart is the dark palette of the same seed" do
      for seed <- @seeds do
        assert PaletteDerivation.derive_palette(seed, :light).dark_colors ==
                 PaletteDerivation.derive_palette(seed, :dark).colors
      end
    end

    test "an invalid or missing seed derives nothing in either mode" do
      assert PaletteDerivation.derive_palette(nil, :light) == nil
      assert PaletteDerivation.derive_palette("#zzzzzz", :light) == nil
      assert PaletteDerivation.derive_palette("#1234", :dark) == nil
    end
  end

  # Approximate relative luminance from hex — good enough to compare two colours.
  defp luminance("#" <> rgb) do
    {r, g, b} =
      case String.length(rgb) do
        6 ->
          {String.to_integer(String.slice(rgb, 0, 2), 16),
           String.to_integer(String.slice(rgb, 2, 2), 16),
           String.to_integer(String.slice(rgb, 4, 2), 16)}

        _other ->
          {0, 0, 0}
      end

    (r * 0.299 + g * 0.587 + b * 0.114) / 255
  end

  describe "hover_for/1" do
    test "hover_for/1 darkens the colour it is given" do
      hover = PaletteDerivation.hover_for("#e11d48")

      assert Colour.relative_luminance(hover) < Colour.relative_luminance("#e11d48")
    end

    test "hover_for/1 returns nil for an invalid colour" do
      assert PaletteDerivation.hover_for("not-a-colour") == nil
    end
  end
end
