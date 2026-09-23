defmodule Tymeslot.Security.UrlValidationLocalHostsTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.UrlValidation

  describe "validate_http_url/2" do
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

    test "classifies uppercase IPv6 addresses as local, waiving the HTTPS requirement" do
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

    test "classifies IPv4-mapped IPv6 addresses as local, waiving the HTTPS requirement" do
      # These hosts are recognised through the IPv4-mapped form, so the public-HTTPS
      # rule does not apply. Blocking them outright is asserted separately by the
      # block_private_ips tests in UrlValidationPrivateIpsTest.
      # AWS metadata endpoint via IPv6-mapped
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

    test "recognises IPv6 addresses with zone IDs as local" do
      # Zone IDs (e.g. %eth0) scope an address to one local interface, so the
      # host is local and exempt from the HTTPS requirement. `URI.parse/1`
      # truncates the authority here, so the host is re-derived from it.
      assert :ok =
               UrlValidation.validate_http_url("http://[fe80::1%eth0]",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "rejects IPv6 addresses without brackets in HTTP URLs" do
      # IPv6 addresses must be bracketed in URLs. Unbracketed, the authority is
      # ambiguous (`URI.parse/1` reads `::1` as a port), so it is rejected.
      assert {:error, "invalid url"} =
               UrlValidation.validate_http_url("http://fe80::1",
                 enforce_https_for_public: true,
                 https_error_message: "https required",
                 invalid_message: "invalid url"
               )
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
      # Invalid IPv4 octets (>255) make the literal unparseable. A bracketed
      # host that is not a valid IPv6 address cannot be classified, so it is
      # rejected rather than assumed public.
      assert {:error, "invalid url"} =
               UrlValidation.validate_http_url("http://[::ffff:999.999.999.999]",
                 enforce_https_for_public: true,
                 https_error_message: "https required",
                 invalid_message: "invalid url"
               )
    end
  end
end
