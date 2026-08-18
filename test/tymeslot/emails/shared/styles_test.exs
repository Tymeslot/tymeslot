defmodule Tymeslot.Emails.Shared.StylesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Styles
  alias Tymeslot.Emails.Shared.Styles.BrandPalette
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Utils.Colour

  describe "button_text_color/1" do
    test "picks dark ink for the stock brand accent" do
      assert Styles.button_text_color("#14b8a6") == Tokens.ink()
    end

    test "picks dark ink for a pale yellow accent" do
      assert Styles.button_text_color("#fde047") == Tokens.ink()
    end

    test "picks dark ink for a pale pink accent" do
      assert Styles.button_text_color("#f9a8d4") == Tokens.ink()
    end

    test "picks the light surface tone for a dark accent" do
      assert Styles.button_text_color("#0f172a") == Tokens.surface()
    end

    test "clears WCAG AA (4.5:1) for the stock accent and both pathological pale seeds" do
      for background <- ["#14b8a6", "#fde047", "#f9a8d4", "#0f172a"] do
        text = Styles.button_text_color(background)

        assert Colour.contrast_ratio(text, background) >= 4.5,
               "expected #{text} on #{background} to clear 4.5:1"
      end
    end

    test "picks the light surface tone for the stock brand deep, not dark ink" do
      # Buttons render on `Tokens.intent_accent_deep/1`, not the raw accent —
      # this pins the regression the deep-background change exists to
      # prevent: a stock button reading as dark ink on turquoise.
      assert Styles.button_text_color("#0d786c") == Tokens.surface()

      assert Colour.contrast_ratio(Tokens.surface(), "#0d786c") >= 4.5
    end

    test "every intent's button surface clears AA, including the fixed signal families" do
      # Buttons render on `accent_deep` for all three intents, so each family's
      # `deep` has to carry text. Rose sat at 4.48:1 until it was darkened;
      # this pins that it stays above the bar.
      for intent <- [:confirmed, :alert, :cancelled] do
        background = Tokens.intent_accent_deep(intent)
        text = Styles.button_text_color(background)

        assert Colour.contrast_ratio(text, background) >= 4.5,
               "#{intent}: expected #{text} on #{background} to clear 4.5:1"
      end
    end

    test "the stage band clears AA for the brand and cancelled families" do
      # `deep` also backs the stage band, drawn in near-white band text. Amber
      # is a known exception at 2.99:1 — a pre-existing defect in the alert
      # family that predates email branding and needs a design decision on the
      # alert band's colour, so it is deliberately not asserted here.
      for intent <- [:confirmed, :cancelled] do
        assert Colour.contrast_ratio(
                 BrandPalette.band_text(),
                 Tokens.intent_accent_deep(intent)
               ) >= 4.5,
               "#{intent}: stage band text fails 4.5:1"
      end
    end
  end
end
