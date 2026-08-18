defmodule Tymeslot.Utils.ColourTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Utils.Colour

  doctest Tymeslot.Utils.Colour

  describe "parse_hex/1" do
    test "parses the six-character form with and without a leading hash" do
      assert Colour.parse_hex("#14b8a6") == {20, 184, 166}
      assert Colour.parse_hex("14b8a6") == {20, 184, 166}
    end

    test "expands the three-character shorthand" do
      assert Colour.parse_hex("#f0a") == {255, 0, 170}
    end

    test "accepts the eight-character form and discards the alpha pair" do
      assert Colour.parse_hex("#14b8a680") == {20, 184, 166}
    end

    test "is case-insensitive and tolerates surrounding whitespace" do
      assert Colour.parse_hex("  #14B8A6  ") == {20, 184, 166}
    end

    test "returns nil for non-hex digits, wrong lengths, and non-strings" do
      assert Colour.parse_hex("#gggggg") == nil
      assert Colour.parse_hex("#12345") == nil
      assert Colour.parse_hex("") == nil
      assert Colour.parse_hex(nil) == nil
      assert Colour.parse_hex(:turquoise) == nil
    end

    test "rejects a leading sign that Integer.parse/2 would otherwise accept" do
      assert Colour.parse_hex("#-1abcd") == nil
      assert Colour.parse_hex("+f00ff") == nil
      assert Colour.parse_hex("-1-2-3") == nil
    end

    test "rejects a malformed alpha pair in the eight-character form" do
      assert Colour.parse_hex("#14b8a6zz") == nil
    end
  end

  describe "normalise_hex/1" do
    test "collapses every accepted form to lowercase #rrggbb" do
      assert Colour.normalise_hex("#14B8A6") == "#14b8a6"
      assert Colour.normalise_hex("f0a") == "#ff00aa"
    end

    test "returns nil rather than passing invalid input through" do
      assert Colour.normalise_hex("teal") == nil
    end

    test "rejects a leading sign that would otherwise round-trip" do
      assert Colour.normalise_hex("#-1abcd") == nil
      assert Colour.normalise_hex("+f00ff") == nil
      assert Colour.normalise_hex("-1-2-3") == nil
    end
  end

  describe "HSL round-tripping" do
    test "returns the original colour for a sample across the hue wheel" do
      for hex <- ~w(#14b8a6 #f59e0b #e26d5c #7c3aed #0f172a #ffffff #000000 #808080) do
        assert hex |> Colour.hex_to_hsl() |> Colour.hsl_to_hex() == hex
      end
    end

    test "reports zero saturation for greys, whatever their lightness" do
      for hex <- ~w(#000000 #808080 #ffffff) do
        assert {_h, +0.0, _l} = Colour.hex_to_hsl(hex)
      end
    end
  end

  describe "contrast_ratio/2" do
    test "spans the full WCAG range" do
      assert Colour.contrast_ratio("#000000", "#ffffff") == 21.0
      assert Colour.contrast_ratio("#14b8a6", "#14b8a6") == 1.0
    end

    test "is symmetric in its arguments" do
      assert Colour.contrast_ratio("#0f5954", "#e1f7f3") ==
               Colour.contrast_ratio("#e1f7f3", "#0f5954")
    end

    test "accepts RGB tuples as well as hex strings" do
      assert Colour.contrast_ratio({0, 0, 0}, {255, 255, 255}) == 21.0
    end

    test "confirms the stock email palette clears its WCAG targets" do
      # Body text on the badge tint is normal weight, so it needs 4.5:1.
      assert Colour.contrast_ratio("#0f5954", "#e1f7f3") >= 4.5

      # Stage band text is large and bold, so 3.0:1 is the applicable bar.
      assert Colour.contrast_ratio("#f8f8f5", "#0d9488") >= 3.0
    end

    test "does not round up a ratio that is truly just below a WCAG threshold" do
      assert Colour.contrast_ratio("#ffffff", "#d88000") < 3.0
      assert Colour.contrast_ratio("#ffffff", "#ef0000") < 4.5
    end
  end

  describe "darken_until_contrast/4" do
    test "leaves a colour that already clears the threshold untouched" do
      hsl = Colour.hex_to_hsl("#0d9488")

      assert Colour.darken_until_contrast(hsl, "#f8f8f5", 3.0) == hsl
    end

    test "darkens a pale colour until it clears the threshold" do
      pale = Colour.hex_to_hsl("#f5d90a")

      darkened = Colour.darken_until_contrast(pale, "#f8f8f5", 3.0)

      assert Colour.contrast_ratio(Colour.hsl_to_hex(darkened), "#f8f8f5") >= 3.0
      assert {_h, _s, lightness} = darkened
      assert lightness < elem(pale, 2)
    end

    test "preserves hue while darkening, so the result stays on-brand" do
      {hue, _s, _l} = pale = Colour.hex_to_hsl("#f5d90a")

      assert {^hue, _s, _l} = Colour.darken_until_contrast(pale, "#f8f8f5", 3.0)
    end

    test "stops as soon as the threshold is met rather than over-darkening" do
      # Darkening a colour raises its contrast against white, so this does
      # terminate — the point is that it stops at the first passing value.
      lightened = Colour.darken_until_contrast(Colour.hex_to_hsl("#ffffff"), "#ffffff", 3.0)

      assert Colour.contrast_ratio(Colour.hsl_to_hex(lightened), "#ffffff") >= 3.0
      assert {_h, _s, lightness} = lightened
      assert lightness > 0.0
    end

    test "bottoms out at black rather than looping when the target is unreachable" do
      # Darkening toward black moves *away* from contrast with black, so no
      # amount of darkening reaches 3:1 and the loop must terminate on its own.
      dark = Colour.hex_to_hsl("#333333")

      assert {_h, _s, +0.0} = Colour.darken_until_contrast(dark, "#000000", 3.0)
    end
  end

  describe "wrap_hue/1" do
    test "wraps into [0, 360)" do
      assert Colour.wrap_hue(-15) == 345.0
      assert Colour.wrap_hue(375) == 15.0
      assert Colour.wrap_hue(360) == 0.0
      assert Colour.wrap_hue(180) == 180.0
    end
  end
end
