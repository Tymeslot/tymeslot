defmodule Tymeslot.Emails.Shared.Styles.BrandPaletteTest do
  use ExUnit.Case, async: false

  @moduletag :emails

  alias Tymeslot.Emails.Branding
  alias Tymeslot.Emails.Shared.Styles.BrandPalette
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Utils.Colour

  doctest Tymeslot.Emails.Shared.Styles.BrandPalette

  # These tests deliberately move the accent around within one BEAM. The
  # derivation cache is keyed by seed hex (`cached/1` matches on
  # `{^hex, family}`), so a changed seed replaces the cached entry rather than
  # serving a stale one — no manual reset is needed between tests.
  setup do
    original = Application.get_env(:tymeslot, :email_brand_accent)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :email_brand_accent)
        value -> Application.put_env(:tymeslot, :email_brand_accent, value)
      end
    end)

    :ok
  end

  describe "derive/1" do
    test "returns nil for anything that is not a hex colour" do
      assert BrandPalette.derive(nil) == nil
      assert BrandPalette.derive("") == nil
      assert BrandPalette.derive("turquoise") == nil
    end

    test "keeps the seed verbatim as the accent" do
      assert %{accent: "#7c3aed"} = BrandPalette.derive("#7c3aed")
    end

    test "normalises the seed before using it" do
      assert %{accent: "#7c3aed"} = BrandPalette.derive("#7C3AED")
    end

    test "reproduces the hand-tuned ink and tint closely enough to be invisible" do
      derived = BrandPalette.derive("#14b8a6")

      # Not an equality assertion: the transforms are calibrated against the
      # hand-tuned values rather than fitted to them exactly. What matters is
      # that seeding with the stock accent does not visibly change the emails.
      #
      # `deep` is asserted separately below: `Branding.stock_family/0` now
      # ships a hand-tuned deep that already clears 4.5:1 against band text
      # (unlike the old "#0d9488", which only managed ≈3.52:1), so re-deriving
      # from the stock accent lands close to it rather than diverging.
      assert derived.accent == "#14b8a6"
      assert Colour.contrast_ratio(derived.ink, "#0f5954") <= 1.05
      assert Colour.contrast_ratio(derived.tint, "#e1f7f3") <= 1.05
    end

    test "darkens the stock accent's deep token past the hand-tuned value to clear 4.5:1" do
      derived = BrandPalette.derive("#14b8a6")

      # `Branding.stock_family/0` (what an instance with no configured accent
      # actually renders with) is unaffected: it is returned verbatim and
      # never reaches `derive/1`. This only applies to an admin who
      # explicitly retypes the stock hex as their own accent.
      assert Colour.contrast_ratio(BrandPalette.band_text(), derived.deep) >= 4.5
    end

    test "derives a tint light enough and an ink dark enough to read as a pair" do
      %{ink: ink, tint: tint} = BrandPalette.derive("#7c3aed")

      assert Colour.contrast_ratio(ink, tint) >= 4.5
    end

    test "keeps band text legible on the derived deep colour" do
      %{deep: deep} = BrandPalette.derive("#7c3aed")

      assert Colour.contrast_ratio(BrandPalette.band_text(), deep) >= 4.5
    end
  end

  describe "family/0" do
    test "returns the stock family verbatim, bypassing the clamp, when no accent is configured" do
      Application.delete_env(:tymeslot, :email_brand_accent)

      assert BrandPalette.family() == Branding.stock_family()
    end
  end

  describe "contrast clamping" do
    # A pale yellow is the case the clamp exists for: derived naively, both the
    # band and the badge text would be unreadable.
    @pale_seed "#f5d90a"

    test "darkens the deep token until band text clears the normal-text bar" do
      %{deep: deep} = BrandPalette.derive(@pale_seed)

      assert Colour.contrast_ratio(BrandPalette.band_text(), deep) >= 4.5
    end

    test "darkens the ink token until body text clears the normal-text bar" do
      %{ink: ink, tint: tint} = BrandPalette.derive(@pale_seed)

      assert Colour.contrast_ratio(ink, tint) >= 4.5
    end

    test "holds for every seed across the hue wheel" do
      for hue <- 0..350//10 do
        seed = Colour.hsl_to_hex({hue * 1.0, 0.9, 0.6})
        %{deep: deep, ink: ink, tint: tint} = BrandPalette.derive(seed)

        assert Colour.contrast_ratio(BrandPalette.band_text(), deep) >= 4.5,
               "band text fails on seed #{seed}"

        assert Colour.contrast_ratio(ink, tint) >= 4.5, "badge text fails on seed #{seed}"
      end
    end
  end

  describe "caching" do
    test "a changed accent replaces the memoised family rather than serving a stale one" do
      first = BrandPalette.derive("#7c3aed")
      second = BrandPalette.derive("#e11d48")

      assert first.accent == "#7c3aed"
      assert second.accent == "#e11d48"
      refute first.deep == second.deep
    end

    test "repeated derivation of the same seed is stable" do
      assert BrandPalette.derive("#7c3aed") == BrandPalette.derive("#7c3aed")
    end
  end

  describe "Tokens.intent/1 integration" do
    test "falls back to the stock turquoise when no accent is configured" do
      Application.delete_env(:tymeslot, :email_brand_accent)

      assert %{accent: "#14b8a6", accent_deep: "#0d786c", tint: "#e1f7f3"} =
               Tokens.intent(:confirmed)
    end

    test "falls back to the stock turquoise when the configured accent is unparseable" do
      Application.put_env(:tymeslot, :email_brand_accent, "not-a-colour")

      assert %{accent: "#14b8a6"} = Tokens.intent(:confirmed)
    end

    test "resolves the confirmed family against the configured accent" do
      Application.put_env(:tymeslot, :email_brand_accent, "#7c3aed")

      tokens = Tokens.intent(:confirmed)

      assert tokens.accent == "#7c3aed"
      assert tokens.band_color == tokens.accent_deep
    end

    test "leaves the alert and cancelled families untouched by the brand accent" do
      Application.put_env(:tymeslot, :email_brand_accent, "#7c3aed")

      assert %{accent: "#f59e0b"} = Tokens.intent(:alert)
      assert %{accent: "#e26d5c"} = Tokens.intent(:cancelled)
    end

    test "still raises on an intent outside the taxonomy" do
      # Picked at runtime so the type checker cannot narrow the argument and
      # flag the deliberately-invalid call as a type error.
      unknown = Enum.random([:rescheduled])

      assert_raise FunctionClauseError, fn -> Tokens.intent(unknown) end
    end
  end
end
