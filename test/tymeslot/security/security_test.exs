defmodule Tymeslot.Security.SecurityTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.Security

  describe "validate_timezone/1" do
    test "accepts valid timezones" do
      assert {:ok, "Europe/Kyiv"} = Security.validate_timezone("Europe/Kyiv")
      assert {:ok, "UTC"} = Security.validate_timezone("UTC")
      assert {:ok, "Etc/UTC"} = Security.validate_timezone("Etc/UTC")
    end

    test "accepts real zones a format regex would reject" do
      # Regression: a prior format check rejected these, silently discarding the
      # visitor's choice even though the picker offers them.
      assert {:ok, _tz} = Security.validate_timezone("America/Argentina/Buenos_Aires")
      assert {:ok, _tz} = Security.validate_timezone("America/Indiana/Indianapolis")
      assert {:ok, _tz} = Security.validate_timezone("Etc/GMT+5")
    end

    test "rejects invalid formats" do
      assert {:error, "Unknown timezone"} = Security.validate_timezone("InvalidTimezone")
      assert {:error, "Unknown timezone"} = Security.validate_timezone("Europe/Kyiv/Kiev")
    end

    test "rejects an oversized string before the zone lookup" do
      assert {:error, "Timezone too long"} =
               Security.validate_timezone(String.duplicate("a", 101))
    end

    test "rejects non-string values" do
      assert {:error, "Invalid timezone"} = Security.validate_timezone(123)
    end
  end

  describe "validate_domain/1" do
    test "accepts valid domains" do
      assert {:ok, "example.com"} = Security.validate_domain("example.com")
      assert {:ok, "sub.example.co.uk"} = Security.validate_domain("sub.example.co.uk")
      assert {:ok, "my-domain.com"} = Security.validate_domain("my-domain.com")
      assert {:ok, "example.co.uk"} = Security.validate_domain("example.co.uk")
      assert {:ok, "example.de"} = Security.validate_domain("example.de")
    end

    test "accepts local development hosts" do
      assert {:ok, "localhost"} = Security.validate_domain("localhost")
      assert {:ok, "127.0.0.1"} = Security.validate_domain("127.0.0.1")
      assert {:ok, "::1"} = Security.validate_domain("::1")
    end

    test "accepts 'none'" do
      assert {:ok, "none"} = Security.validate_domain("none")
    end

    test "strips protocol and accepts the bare domain" do
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com")
      assert {:ok, "localhost"} = Security.validate_domain("http://localhost")
    end

    test "strips protocol, trailing slash, and path" do
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com/")
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com/path")
    end

    test "strips protocol and port" do
      assert {:ok, "example.com"} = Security.validate_domain("https://example.com:443")
      assert {:ok, "localhost"} = Security.validate_domain("http://localhost:4000")
    end

    test "rejects domains with paths (no protocol)" do
      assert {:error, _reason} = Security.validate_domain("example.com/path")
    end

    test "rejects domains with ports (no protocol)" do
      assert {:error, _reason} = Security.validate_domain("example.com:8080")
      assert {:error, _reason} = Security.validate_domain("localhost:4000")
    end

    test "rejects invalid formats" do
      assert {:error, _reason} = Security.validate_domain("-example.com")
      assert {:error, _reason} = Security.validate_domain("example-.com")
      assert {:error, _reason} = Security.validate_domain("example..com")
    end

    test "rejects overly long domains" do
      long_domain = String.duplicate("a", 256) <> ".com"

      assert {:error, "Some domains exceed maximum length (max 255 characters)"} =
               Security.validate_domain(long_domain)
    end
  end

  describe "validate_domain/1 TLD validation" do
    test "rejects domains with invalid TLDs" do
      {:error, msg} = Security.validate_domain("example.or")
      assert msg =~ "unrecognised"
      assert msg =~ ".or"
    end

    test "includes suggestion when confident" do
      {:error, msg} = Security.validate_domain("example.ocm")
      assert msg =~ "did you mean .com?"
    end

    test "accepts wildcard domains with valid TLDs" do
      assert {:ok, "*.example.com"} = Security.validate_domain("*.example.com")
    end

    test "rejects wildcard domains with invalid TLDs" do
      {:error, msg} = Security.validate_domain("*.example.or")
      assert msg =~ "unrecognised"
    end
  end
end
