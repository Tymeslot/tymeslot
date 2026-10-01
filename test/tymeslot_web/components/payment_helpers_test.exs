defmodule TymeslotWeb.Components.PaymentHelpersTest do
  use ExUnit.Case, async: true

  alias TymeslotWeb.Components.PaymentHelpers

  @nbsp " "

  describe "format_amount/3" do
    test "puts the symbol flush before the number in English" do
      assert PaymentHelpers.format_amount(4500, "eur", "en") == "€45.00"
      assert PaymentHelpers.format_amount(123_450, "gbp", "en") == "£1,234.50"
    end

    test "sets a letter code off from the number in English" do
      assert PaymentHelpers.format_amount(4500, "chf", "en") == "CHF 45.00"
    end

    test "puts the symbol after the number, behind a non-breaking space, in German" do
      assert PaymentHelpers.format_amount(4500, "eur", "de") == "45,00" <> @nbsp <> "€"
      assert PaymentHelpers.format_amount(123_450, "eur", "de") == "1.234,50" <> @nbsp <> "€"
    end

    test "groups with a non-breaking space in French and Czech" do
      assert PaymentHelpers.format_amount(123_450, "eur", "fr") ==
               "1" <> @nbsp <> "234,50" <> @nbsp <> "€"

      assert PaymentHelpers.format_amount(123_450, "chf", "cs") ==
               "1" <> @nbsp <> "234,50" <> @nbsp <> "CHF"
    end

    test "formats an unknown locale as English" do
      assert PaymentHelpers.format_amount(123_450, "eur", "xx") == "€1,234.50"
    end

    test "is empty when the amount is not an integer" do
      assert PaymentHelpers.format_amount(nil, "eur", "de") == ""
    end
  end

  describe "format_amount/2" do
    test "keeps the dashboard's symbol-first format" do
      assert PaymentHelpers.format_amount(4500, "eur") == "€45.00"
      assert PaymentHelpers.format_amount(4500, "chf") == "CHF 45.00"
    end
  end
end
