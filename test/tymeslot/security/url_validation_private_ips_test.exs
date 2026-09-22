defmodule Tymeslot.Security.UrlValidationPrivateIpsTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.UrlValidation

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

  describe "validate_http_url/2 IPv6 authority parsing" do
    @private_ip_opts [block_private_ips: true]
    @https_opts [enforce_https_for_public: true, https_error_message: "https required"]
    @invalid_message "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"
    @private_ip_message "Private or local network addresses are not allowed"

    # `URI.parse/1` truncates `[fe80::1%eth0]` to the host "fe80", so the
    # zone-stripping in the IPv6 check never saw the address and the host was
    # allowed through under block_private_ips.
    test "blocks zoned link-local literals when private IPs are blocked" do
      for url <- [
            "http://[fe80::1%eth0]/",
            "https://[fe80::1%eth0]/hook",
            "https://[fe80::1%25eth0]/hook",
            "https://[FE80::1%eth0]/hook"
          ] do
        assert {:error, @private_ip_message} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected as private"
      end
    end

    test "treats zoned link-local literals as local under enforce_https_for_public" do
      # Scoped addresses are never publicly routable, so HTTPS is not enforced.
      assert :ok = UrlValidation.validate_http_url("http://[fe80::1%eth0]/", @https_opts)
    end

    # `URI.parse/1` read `fe80::1` as host "fe80" with port `:1`.
    test "rejects unbracketed IPv6 literals as malformed" do
      for url <- [
            "http://fe80::1",
            "https://fe80::1/hook",
            "http://::1",
            "https://::ffff:10.0.0.1/"
          ] do
        assert {:error, @invalid_message} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected as malformed"

        assert {:error, _reason} = UrlValidation.validate_http_url(url, @https_opts),
               "expected #{url} to be rejected as malformed"
      end
    end

    # Anything bracketed must be an IPv6 literal; unclassifiable hosts fail closed.
    test "rejects bracketed hosts that are not valid IPv6 literals" do
      for url <- [
            "http://[::ffff:999.999.999.999]/",
            "https://[::ffff:999.999.999.999]/hook",
            "https://[::ffff:127.1]/hook",
            "https://[not-an-address]/hook",
            "https://[fe80::1/hook"
          ] do
        assert {:error, @invalid_message} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected as malformed"

        assert {:error, _reason} = UrlValidation.validate_http_url(url, @https_opts),
               "expected #{url} to be rejected as malformed"
      end
    end

    test "blocks private IPv6 literals that carry a port or userinfo" do
      for url <- [
            "https://[::1]:8443/hook",
            "https://[fe80::1]:443/hook",
            "https://[fc00::1]:8080/hook",
            "https://[::ffff:127.0.0.1]:9000/hook",
            "https://[::ffff:10.0.0.1]:9000/hook",
            "https://user:pass@[::1]/hook",
            "https://user:pass@[fe80::1]:8443/hook"
          ] do
        assert {:error, @private_ip_message} =
                 UrlValidation.validate_http_url(url, @private_ip_opts),
               "expected #{url} to be rejected as private"
      end
    end

    test "still allows public IPv6 literals when private IPs are blocked" do
      assert :ok = UrlValidation.validate_http_url("https://[2001:db8::1]/hook", @private_ip_opts)

      assert :ok =
               UrlValidation.validate_http_url("https://[::ffff:8.8.8.8]/hook", @private_ip_opts)

      assert :ok =
               UrlValidation.validate_http_url(
                 "https://[2606:4700::1]:8443/hook",
                 @private_ip_opts
               )
    end
  end
end
