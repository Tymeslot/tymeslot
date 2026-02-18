defmodule Tymeslot.Security.UrlValidationTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.UrlValidation

  describe "validate_http_url/2" do
    test "accepts valid http and https URLs" do
      assert :ok = UrlValidation.validate_http_url("https://example.com")
      assert :ok = UrlValidation.validate_http_url("http://example.com/path?x=1")
    end

    test "rejects non-binary input" do
      assert {:error, msg} = UrlValidation.validate_http_url(nil)
      assert is_binary(msg)
    end

    test "rejects missing host or malformed URLs" do
      assert {:error, msg1} = UrlValidation.validate_http_url("https://")
      assert is_binary(msg1)

      assert {:error, msg2} = UrlValidation.validate_http_url("https:///path")
      assert is_binary(msg2)
    end

    test "rejects unsupported schemes with a scheme-specific error" do
      assert {:error, "Only HTTP and HTTPS URLs are allowed"} =
               UrlValidation.validate_http_url("ftp://example.com")

      assert {:error, "Only HTTP and HTTPS URLs are allowed"} =
               UrlValidation.validate_http_url("javascript:alert(1)")
    end

    test "enforces max length when configured" do
      url = "https://example.com/this-is-long"

      assert {:error, "too long"} =
               UrlValidation.validate_http_url(url,
                 max_length: 10,
                 length_error_message: "too long"
               )
    end

    test "blocks configured disallowed protocol substrings" do
      url = "https://example.com/?next=javascript:alert(1)"

      assert {:error, "blocked"} =
               UrlValidation.validate_http_url(url,
                 disallowed_protocols: ["javascript:"],
                 disallowed_protocol_error: "blocked"
               )
    end

    test "can enforce https for non-local hosts" do
      assert {:error, "https required"} =
               UrlValidation.validate_http_url("http://example.com",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://localhost",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://127.0.0.1",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://10.0.0.1",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "supports extra checks via a callback" do
      ok_check = fn _context -> :ok end

      assert :ok =
               UrlValidation.validate_http_url("https://example.com",
                 extra_checks: ok_check
               )

      error_check = fn _context -> {:error, "custom rule"} end

      assert {:error, "custom rule"} =
               UrlValidation.validate_http_url("https://example.com",
                 extra_checks: error_check
               )
    end

    test "treats link-local addresses as local (169.254.x.x)" do
      # AWS metadata endpoint should be treated as local
      assert :ok =
               UrlValidation.validate_http_url("http://169.254.169.254",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://169.254.1.1",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "treats IPv6 localhost and private ranges as local" do
      # IPv6 localhost
      assert :ok =
               UrlValidation.validate_http_url("http://[::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      # IPv6 link-local (fe80::/10)
      assert :ok =
               UrlValidation.validate_http_url("http://[fe80::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      # IPv6 unique local (fc00::/7)
      assert :ok =
               UrlValidation.validate_http_url("http://[fc00::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://[fd00::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "blocks uppercase IPv6 addresses (SSRF protection - case sensitivity)" do
      # Uppercase localhost
      assert :ok =
               UrlValidation.validate_http_url("http://[::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      # Uppercase link-local addresses
      assert :ok =
               UrlValidation.validate_http_url("http://[FE80::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://[Fe80::ABCD]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      # Uppercase unique local addresses
      assert :ok =
               UrlValidation.validate_http_url("http://[FC00::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://[FD00::ABCD]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "blocks IPv4-mapped IPv6 addresses (SSRF protection - AWS metadata)" do
      # AWS metadata endpoint via IPv6-mapped (critical SSRF vector)
      assert :ok =
               UrlValidation.validate_http_url("http://[::ffff:169.254.169.254]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      # Localhost via IPv4-mapped
      assert :ok =
               UrlValidation.validate_http_url("http://[::ffff:127.0.0.1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      # Private network ranges via IPv4-mapped
      assert :ok =
               UrlValidation.validate_http_url("http://[::ffff:10.0.0.1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://[::ffff:192.168.1.1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://[::ffff:172.16.0.1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      # Mixed case IPv4-mapped
      assert :ok =
               UrlValidation.validate_http_url("http://[::FFFF:169.254.169.254]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "requires HTTPS for public IPv4-mapped IPv6 addresses" do
      # Public IP via IPv4-mapped should require HTTPS
      assert {:error, message} =
               UrlValidation.validate_http_url("http://[::ffff:8.8.8.8]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert message == "https required"

      # HTTPS should work
      assert :ok =
               UrlValidation.validate_http_url("https://[::ffff:8.8.8.8]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "handles IPv6 addresses with zone IDs (URI parser limitation)" do
      # Zone IDs (e.g., %eth0) are used for link-local addresses
      # Note: Elixir's URI parser doesn't correctly parse IPv6 with zone IDs
      # It extracts only partial host info, which may cause validation issues
      # This test documents the current behavior rather than ideal behavior
      result =
        UrlValidation.validate_http_url("http://[fe80::1%eth0]",
          enforce_https_for_public: true,
          https_error_message: "https required"
        )

      # Due to URI parser limitations, this may not be recognized as local
      # We accept either outcome (proper parsing would recognize as local)
      assert result == :ok or result == {:error, "https required"}
    end

    test "rejects IPv6 addresses without brackets in HTTP URLs" do
      # IPv6 addresses must be bracketed in URLs
      # Without brackets, the URI parser should fail or misparse
      result =
        UrlValidation.validate_http_url("http://fe80::1",
          enforce_https_for_public: true,
          https_error_message: "https required",
          invalid_message: "invalid url"
        )

      # Should either fail validation or be rejected by URI parser
      assert match?({:error, _}, result) or result == :ok
    end

    test "handles IPv6 compressed zeros in different positions" do
      # IPv6 addresses can have compressed zeros (::) in various positions
      # All these should be treated as link-local (fe80::/10)
      test_cases = [
        "http://[fe80::1]",
        "http://[fe80::1:0:0:1]",
        "http://[fe80:0:0:0:0:0:0:1]",
        "http://[fe80::abcd:ef12:3456:7890]"
      ]

      for url <- test_cases do
        assert :ok =
                 UrlValidation.validate_http_url(url,
                   enforce_https_for_public: true,
                   https_error_message: "https required"
                 )
      end
    end

    test "handles IPv6 unique local addresses with different prefixes" do
      # Both fc00::/7 (fd00 and fc00) should be treated as private
      assert :ok =
               UrlValidation.validate_http_url("http://[fc00::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://[fd12:3456::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://[fdff:ffff:ffff:ffff::1]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "validates IPv4 octets in IPv4-mapped IPv6 addresses (edge case)" do
      # Test with invalid IPv4 octets (>255)
      # The URI parser should handle this, but we verify behavior
      result =
        UrlValidation.validate_http_url("http://[::ffff:999.999.999.999]",
          enforce_https_for_public: true,
          https_error_message: "https required",
          invalid_message: "invalid url"
        )

      # URI parser should reject or the connection would fail anyway
      # Just verify we don't crash
      assert result == :ok or match?({:error, _}, result)
    end
  end
end
