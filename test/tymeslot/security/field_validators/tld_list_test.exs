defmodule Tymeslot.Security.FieldValidators.TLDListTest do
  use ExUnit.Case, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.TLDList

  describe "valid_public_tld?/1" do
    test "returns true for common TLDs" do
      assert TLDList.valid_public_tld?("com")
      assert TLDList.valid_public_tld?("org")
      assert TLDList.valid_public_tld?("net")
      assert TLDList.valid_public_tld?("de")
      assert TLDList.valid_public_tld?("uk")
    end

    test "returns true for generic TLDs" do
      assert TLDList.valid_public_tld?("app")
      assert TLDList.valid_public_tld?("dev")
      assert TLDList.valid_public_tld?("io")
    end

    test "returns true for country code TLDs" do
      assert TLDList.valid_public_tld?("ai")
      assert TLDList.valid_public_tld?("cc")
      assert TLDList.valid_public_tld?("gg")
    end

    test "returns true for second-level TLDs" do
      assert TLDList.valid_public_tld?("co.uk")
      assert TLDList.valid_public_tld?("com.au")
      assert TLDList.valid_public_tld?("org.nz")
    end

    test "is case-insensitive" do
      assert TLDList.valid_public_tld?("COM")
      assert TLDList.valid_public_tld?("Org")
      assert TLDList.valid_public_tld?("Co.Uk")
    end

    test "returns false for special_use TLDs" do
      refute TLDList.valid_public_tld?("localhost")
      refute TLDList.valid_public_tld?("test")
      refute TLDList.valid_public_tld?("local")
      refute TLDList.valid_public_tld?("onion")
    end

    test "returns false for invalid TLDs" do
      refute TLDList.valid_public_tld?("or")
      refute TLDList.valid_public_tld?("ocm")
      refute TLDList.valid_public_tld?("ogr")
      refute TLDList.valid_public_tld?("cmo")
      refute TLDList.valid_public_tld?("oi")
    end
  end

  describe "suggest_tld/1" do
    test "suggests for transposition typos" do
      assert {:ok, "com"} = TLDList.suggest_tld("ocm")
      assert {:ok, "org"} = TLDList.suggest_tld("ogr")
    end

    test "suggests for extra character typos" do
      assert {:ok, "net"} = TLDList.suggest_tld("nett")
      assert {:ok, "org"} = TLDList.suggest_tld("orgg")
      assert {:ok, "xyz"} = TLDList.suggest_tld("xyzz")
    end

    test "suggests for wrong character typos" do
      assert {:ok, "com"} = TLDList.suggest_tld("cmm")
      assert {:ok, "com"} = TLDList.suggest_tld("comn")
      assert {:ok, "org"} = TLDList.suggest_tld("orh")
      assert {:ok, "net"} = TLDList.suggest_tld("ney")
    end

    test "suggests for second-level TLD typos" do
      assert {:ok, "co.uk"} = TLDList.suggest_tld("co.u")
    end

    test "returns :no_suggestion for ambiguous typos" do
      # "or" is distance 1 from ar, br, fr, gr, org... too ambiguous
      assert :no_suggestion = TLDList.suggest_tld("or")
      # "oi" is distance 1 from fi, io, si... too ambiguous
      assert :no_suggestion = TLDList.suggest_tld("oi")
    end

    test "returns :no_suggestion for valid TLDs" do
      assert :no_suggestion = TLDList.suggest_tld("com")
      assert :no_suggestion = TLDList.suggest_tld("org")
    end

    test "returns :no_suggestion for distant gibberish" do
      assert :no_suggestion = TLDList.suggest_tld("zzzzz")
      assert :no_suggestion = TLDList.suggest_tld("qqqq")
    end
  end

  describe "extract_tld/1" do
    test "extracts single-part TLD" do
      assert "com" = TLDList.extract_tld("example.com")
      assert "org" = TLDList.extract_tld("example.org")
    end

    test "extracts known second-level TLD" do
      assert "co.uk" = TLDList.extract_tld("company.co.uk")
      assert "com.au" = TLDList.extract_tld("shop.com.au")
      assert "ac.jp" = TLDList.extract_tld("uni.ac.jp")
    end

    test "falls back to single-part when second-level is unknown" do
      assert "com" = TLDList.extract_tld("subdomain.example.com")
    end

    test "is case-insensitive" do
      assert "co.uk" = TLDList.extract_tld("Company.Co.Uk")
      assert "com" = TLDList.extract_tld("Example.COM")
    end
  end
end
