defmodule Tymeslot.Security.SecurityTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.Security

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
    test "rejects domains whose ending cannot be a TLD" do
      {:error, msg} = Security.validate_domain("example.c0m")
      assert msg =~ "invalid domain ending"
      assert msg =~ ".c0m"
    end

    test "accepts an embed domain on a newly delegated TLD" do
      assert {:ok, "example.homes"} = Security.validate_domain("example.homes")
    end

    test "includes suggestion when confident" do
      {:error, msg} = Security.validate_domain("example.ocm")
      assert msg =~ "Did you mean .com?"
    end

    test "accepts wildcard domains with valid TLDs" do
      assert {:ok, "*.example.com"} = Security.validate_domain("*.example.com")
    end

    test "rejects wildcard domains whose ending cannot be a TLD" do
      {:error, msg} = Security.validate_domain("*.example.c0m")
      assert msg =~ "invalid domain ending"
    end
  end

  describe "validate_domain/1 in another language" do
    test "explains a malformed domain in the person's language" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert {:error, "Ungültiges Domain-Format (z. B. example.com)"} =
                 Security.validate_domain("example.com/path")
      end)
    end
  end

  describe "validate_domains/1" do
    test "returns each distinct problem as its own message, for the reader's language to join" do
      assert {:error, messages} =
               Security.validate_domains(["example.com/path", "other.org/x", "*.bad_host.com"])

      assert Enum.sort(messages) ==
               Enum.sort([
                 "Invalid domain format (e.g. example.com)",
                 "Invalid domain format (e.g. *.example.com)"
               ])
    end

    test "returns the valid domains when every entry passes" do
      assert {:ok, ["example.com", "*.example.org"]} =
               Security.validate_domains(["example.com", "", "*.example.org"])
    end
  end
end
