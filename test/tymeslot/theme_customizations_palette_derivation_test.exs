defmodule Tymeslot.ThemeCustomizationsPaletteDerivationTest do
  use ExUnit.Case, async: true
  @moduletag :themes

  alias Tymeslot.ThemeCustomizations.PaletteDerivation

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

      assert is_binary(name)

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
end
