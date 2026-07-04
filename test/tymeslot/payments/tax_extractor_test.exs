defmodule Tymeslot.Payments.TaxExtractorTest do
  use ExUnit.Case, async: true

  @moduletag :payments

  alias Tymeslot.Payments.TaxExtractor

  describe "extract_tax_info/1" do
    test "extracts all tax information from a complete session" do
      session = %{
        "total_details" => %{"amount_tax" => 500},
        "customer_details" => %{
          "address" => %{
            "country" => "DE",
            "line1" => "123 Main St"
          },
          "tax_ids" => [%{"type" => "eu_vat", "value" => "DE123456789"}]
        }
      }

      result = TaxExtractor.extract_tax_info(session)

      assert result.tax_amount == 500
      assert result.country_code == "DE"
      assert result.tax_id == "DE123456789"
      assert result.is_eu_business == true
      assert result.billing_address["country"] == "DE"
    end

    test "handles missing tax information gracefully" do
      session = %{}

      result = TaxExtractor.extract_tax_info(session)

      assert result.tax_amount == 0
      assert result.country_code == nil
      assert result.tax_id == nil
      assert result.is_eu_business == false
      assert result.billing_address == nil
    end

    test "identifies non-EU businesses correctly" do
      session = %{
        "customer_details" => %{
          "address" => %{"country" => "US"},
          "tax_ids" => [%{"type" => "us_ein", "value" => "12-3456789"}]
        }
      }

      result = TaxExtractor.extract_tax_info(session)

      assert result.is_eu_business == false
    end
  end

  describe "extract_tax_amount/1" do
    test "extracts integer tax amount" do
      session = %{"total_details" => %{"amount_tax" => 500}}
      assert TaxExtractor.extract_tax_amount(session) == 500
    end

    test "parses string tax amount" do
      session = %{"total_details" => %{"amount_tax" => "500"}}
      assert TaxExtractor.extract_tax_amount(session) == 500
    end

    test "returns 0 for nil tax amount" do
      session = %{"total_details" => %{"amount_tax" => nil}}
      assert TaxExtractor.extract_tax_amount(session) == 0
    end

    test "returns 0 for missing tax details" do
      session = %{}
      assert TaxExtractor.extract_tax_amount(session) == 0
    end

    test "returns 0 for unparseable tax amount" do
      session = %{"total_details" => %{"amount_tax" => "invalid"}}
      assert TaxExtractor.extract_tax_amount(session) == 0
    end

    test "returns 0 for unexpected data types" do
      session = %{"total_details" => %{"amount_tax" => %{"nested" => "value"}}}
      assert TaxExtractor.extract_tax_amount(session) == 0
    end

    test "clamps a negative integer tax amount to 0" do
      session = %{"total_details" => %{"amount_tax" => -500}}
      assert TaxExtractor.extract_tax_amount(session) == 0
    end

    test "clamps a negative string tax amount to 0" do
      session = %{"total_details" => %{"amount_tax" => "-500"}}
      assert TaxExtractor.extract_tax_amount(session) == 0
    end
  end

  describe "extract_tax_id/1" do
    test "extracts tax ID from first tax_ids entry" do
      session = %{
        "customer_details" => %{
          "tax_ids" => [
            %{"type" => "eu_vat", "value" => "DE123456789"},
            %{"type" => "other", "value" => "OTHER123"}
          ]
        }
      }

      assert TaxExtractor.extract_tax_id(session) == "DE123456789"
    end

    test "returns nil for empty tax_ids list" do
      session = %{"customer_details" => %{"tax_ids" => []}}
      assert TaxExtractor.extract_tax_id(session) == nil
    end

    test "returns nil for missing tax_ids" do
      session = %{"customer_details" => %{}}
      assert TaxExtractor.extract_tax_id(session) == nil
    end

    test "returns nil when tax ID has no value" do
      session = %{
        "customer_details" => %{
          "tax_ids" => [%{"type" => "eu_vat"}]
        }
      }

      assert TaxExtractor.extract_tax_id(session) == nil
    end
  end

  describe "eu_business?/1" do
    test "returns true for EU VAT with EU country" do
      session = %{
        "customer_details" => %{
          "tax_ids" => [%{"type" => "eu_vat"}],
          "address" => %{"country" => "DE"}
        }
      }

      assert TaxExtractor.eu_business?(session) == true
    end

    test "returns false for EU VAT with non-EU country" do
      session = %{
        "customer_details" => %{
          "tax_ids" => [%{"type" => "eu_vat"}],
          "address" => %{"country" => "US"}
        }
      }

      assert TaxExtractor.eu_business?(session) == false
    end

    test "returns false for non-EU VAT with EU country" do
      session = %{
        "customer_details" => %{
          "tax_ids" => [%{"type" => "us_ein"}],
          "address" => %{"country" => "DE"}
        }
      }

      assert TaxExtractor.eu_business?(session) == false
    end

    test "returns false when no tax IDs present" do
      session = %{
        "customer_details" => %{
          "address" => %{"country" => "DE"}
        }
      }

      assert TaxExtractor.eu_business?(session) == false
    end

    test "returns false when no country present" do
      session = %{
        "customer_details" => %{
          "tax_ids" => [%{"type" => "eu_vat"}]
        }
      }

      assert TaxExtractor.eu_business?(session) == false
    end

    test "returns false for empty session" do
      assert TaxExtractor.eu_business?(%{}) == false
    end

    test "checks all EU country codes" do
      eu_countries =
        ~w(AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE)

      for country <- eu_countries do
        session = %{
          "customer_details" => %{
            "tax_ids" => [%{"type" => "eu_vat"}],
            "address" => %{"country" => country}
          }
        }

        assert TaxExtractor.eu_business?(session) == true,
               "Expected #{country} to be recognized as EU country"
      end
    end
  end

  describe "eu_country_codes/0" do
    test "returns list of EU country codes" do
      codes = TaxExtractor.eu_country_codes()

      assert is_list(codes)
      assert "DE" in codes
      assert "FR" in codes
      assert "IT" in codes
      assert "ES" in codes
      # Should not include non-EU countries
      refute "US" in codes
      refute "GB" in codes
    end

    test "returns all 27 EU member states" do
      codes = TaxExtractor.eu_country_codes()
      # EU has 27 member states as of 2024
      assert length(codes) == 27
    end
  end
end
