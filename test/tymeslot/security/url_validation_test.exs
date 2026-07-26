defmodule Tymeslot.Security.UrlValidationTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.UrlValidation

  @invalid_url_message "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"

  describe "validate_http_url/2" do
    test "accepts valid http and https URLs" do
      assert :ok = UrlValidation.validate_http_url("https://example.com")
      assert :ok = UrlValidation.validate_http_url("http://example.com/path?x=1")
    end

    test "rejects non-binary input" do
      assert UrlValidation.validate_http_url(nil) == {:error, @invalid_url_message}
    end

    test "rejects missing host or malformed URLs" do
      assert UrlValidation.validate_http_url("https://") == {:error, @invalid_url_message}
      assert UrlValidation.validate_http_url("https:///path") == {:error, @invalid_url_message}
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
      # Zone IDs (e.g., %eth0) are used for link-local addresses. Elixir's URI
      # parser truncates "[fe80::1%eth0]" to the host "fe80", so the zone-stripping
      # in ipv6_local_or_private?/1 never sees the address and it is not recognised
      # as link-local. Under enforce_https_for_public that fails closed: HTTP is
      # rejected rather than silently allowed.
      result =
        UrlValidation.validate_http_url("http://[fe80::1%eth0]",
          enforce_https_for_public: true,
          https_error_message: "https required"
        )

      assert result == {:error, "https required"}
    end

    test "rejects IPv6 addresses without brackets in HTTP URLs" do
      # IPv6 addresses must be bracketed in URLs. Unbracketed, the URI parser
      # reads "fe80" as the host and "::1" as a port, so the address is not
      # recognised as link-local and HTTP is refused for what looks public.
      result =
        UrlValidation.validate_http_url("http://fe80::1",
          enforce_https_for_public: true,
          https_error_message: "https required",
          invalid_message: "invalid url"
        )

      assert result == {:error, "https required"}
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
      # Octets above 255 make the address unparseable, so it is not classified as
      # private and HTTP is refused under enforce_https_for_public.
      result =
        UrlValidation.validate_http_url("http://[::ffff:999.999.999.999]",
          enforce_https_for_public: true,
          https_error_message: "https required",
          invalid_message: "invalid url"
        )

      assert result == {:error, "https required"}
    end
  end

  describe "validate_http_url/2 with block_private_ips option" do
    @private_ip_opts [block_private_ips: true]

    test "rejects localhost" do
      assert {:error, "Private or local network addresses are not allowed"} =
               UrlValidation.validate_http_url("https://localhost/hook", @private_ip_opts)

      assert {:error, "Private or local network addresses are not allowed"} =
               UrlValidation.validate_http_url("https://127.0.0.1/hook", @private_ip_opts)
    end

    test "rejects private IPv4 ranges" do
      for url <- [
            "https://10.0.0.1/hook",
            "https://172.16.5.1/hook",
            "https://172.31.255.1/hook",
            "https://192.168.1.1/hook",
            "https://169.254.169.254/hook"
          ] do
        assert {:error, "Private or local network addresses are not allowed"} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected"
      end
    end

    test "rejects private IPv6 addresses" do
      for url <- [
            "https://[::1]/hook",
            "https://[fe80::1]/hook",
            "https://[fc00::1]/hook",
            "https://[fd00::1]/hook"
          ] do
        assert {:error, "Private or local network addresses are not allowed"} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected"
      end
    end

    test "rejects IPv4-mapped IPv6 private addresses" do
      for url <- [
            "https://[::ffff:127.0.0.1]/hook",
            "https://[::ffff:10.0.0.1]/hook",
            "https://[::ffff:192.168.1.1]/hook",
            "https://[::ffff:169.254.169.254]/hook"
          ] do
        assert {:error, "Private or local network addresses are not allowed"} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected"
      end
    end

    test "allows public URLs" do
      assert :ok = UrlValidation.validate_http_url("https://example.com/hook", @private_ip_opts)
      assert :ok = UrlValidation.validate_http_url("https://8.8.8.8/hook", @private_ip_opts)
    end

    test "does not block private IPs when option is false (default)" do
      assert :ok = UrlValidation.validate_http_url("https://localhost/hook")
      assert :ok = UrlValidation.validate_http_url("https://10.0.0.1/hook")
    end

    test "supports custom error message via :private_ip_error_message" do
      assert {:error, "No local URLs"} =
               UrlValidation.validate_http_url("https://localhost/hook",
                 block_private_ips: true,
                 private_ip_error_message: "No local URLs"
               )
    end

    test "rejects 0.0.0.0 (bound to all interfaces)" do
      assert {:error, "Private or local network addresses are not allowed"} =
               UrlValidation.validate_http_url("http://0.0.0.0/admin", @private_ip_opts)
    end

    test "rejects alternate IPv4 notations that resolve to private addresses" do
      # Decimal (2130706433 == 127.0.0.1), hex, octal, dotted shorthand.
      # HTTP clients resolve these inconsistently — treat any non-canonical
      # numeric host as unsafe when private IPs are blocked.
      for url <- [
            "http://2130706433/",
            "http://0x7f000001/",
            "http://0x7f.0x0.0x0.0x1/",
            "http://0177.0.0.1/",
            "http://127.1/",
            "http://127.0.1/"
          ] do
        assert {:error, "Private or local network addresses are not allowed"} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected"
      end
    end

    test "still allows canonical dotted public IPv4 addresses" do
      assert :ok = UrlValidation.validate_http_url("https://8.8.8.8/hook", @private_ip_opts)
      assert :ok = UrlValidation.validate_http_url("https://1.1.1.1/hook", @private_ip_opts)
    end

    test "rejects LOCALHOST regardless of case" do
      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://LOCALHOST/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://LocalHost/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://LOCALHOST/", @private_ip_opts)
    end

    test "rejects full fe80::/10 link-local range (not just fe80: prefix)" do
      # fe80::/10 covers 0xFE80–0xFEBF in the first hextet
      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[fe80::1]/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[fe90::1]/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[fea0::1]/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[feb0::1]/", @private_ip_opts)
    end

    test "rejects full fc00::/7 unique-local range (fc and fd blocks)" do
      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[fc00::1]/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[fcab::1]/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[fd12::1]/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[fdff::1]/", @private_ip_opts)
    end

    test "rejects IPv6 loopback and IPv4-mapped loopback" do
      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[::1]/", @private_ip_opts)

      assert {:error, _reason} =
               UrlValidation.validate_http_url("http://[::ffff:127.0.0.1]/", @private_ip_opts)
    end

    test "does not over-block real domain names with fc/fd/fe prefix" do
      # These are valid public domain names, not IPv6 addresses
      assert :ok = UrlValidation.validate_http_url("https://fcc.gov/", @private_ip_opts)
      assert :ok = UrlValidation.validate_http_url("https://fd-bakery.com/", @private_ip_opts)
    end

    test "does not over-block real domain names that start with IPv4-like prefixes" do
      # These are valid public domain names, not private IPs
      assert :ok = UrlValidation.validate_http_url("http://10.com/", @private_ip_opts)
      assert :ok = UrlValidation.validate_http_url("http://127.net/", @private_ip_opts)
    end
  end
end
