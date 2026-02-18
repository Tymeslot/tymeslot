defmodule Tymeslot.Infrastructure.ProxyConfigTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.ProxyConfig

  describe "NO_PROXY pattern matching" do
    test "matches exact hostname" do
      assert ProxyConfig.matches_no_proxy_pattern?("internal.example.com", "internal.example.com")
      refute ProxyConfig.matches_no_proxy_pattern?("other.example.com", "internal.example.com")
    end

    test "matches wildcard domain patterns" do
      assert ProxyConfig.matches_no_proxy_pattern?("foo.example.com", "*.example.com")
      assert ProxyConfig.matches_no_proxy_pattern?("bar.example.com", "*.example.com")
      assert ProxyConfig.matches_no_proxy_pattern?("example.com", "*.example.com")
      refute ProxyConfig.matches_no_proxy_pattern?("notexample.com", "*.example.com")
    end

    test "matches wildcard with special case" do
      assert ProxyConfig.matches_no_proxy_pattern?("anything.com", "*")
      assert ProxyConfig.matches_no_proxy_pattern?("192.168.1.1", "*")
    end

    test "matches CIDR ranges for IPv4" do
      assert ProxyConfig.matches_cidr?("192.168.1.100", "192.168.0.0/16")
      assert ProxyConfig.matches_cidr?("10.5.10.20", "10.0.0.0/8")
      refute ProxyConfig.matches_cidr?("172.16.0.1", "192.168.0.0/16")
    end

    test "matches localhost patterns" do
      assert ProxyConfig.matches_no_proxy_pattern?("localhost", "localhost")
      assert ProxyConfig.matches_cidr?("127.0.0.1", "127.0.0.0/8")
    end

    test "rejects invalid CIDR prefix lengths" do
      # IPv4 prefix > 32
      refute ProxyConfig.matches_cidr?("192.168.1.1", "192.168.0.0/33")
      refute ProxyConfig.matches_cidr?("10.0.0.1", "10.0.0.0/64")

      # Negative prefix
      refute ProxyConfig.matches_cidr?("192.168.1.1", "192.168.0.0/-1")

      # IPv6 prefix > 128
      refute ProxyConfig.matches_cidr?("2001:db8::1", "2001:db8::/129")
      refute ProxyConfig.matches_cidr?("2001:db8::1", "2001:db8::/200")
    end

    test "rejects IP version mismatch in CIDR matching" do
      # IPv6 address should not match IPv4 CIDR
      refute ProxyConfig.matches_cidr?("2001:db8::1", "192.168.0.0/16")
      refute ProxyConfig.matches_cidr?("2001:db8::1", "10.0.0.0/8")

      # IPv4 address should not match IPv6 CIDR
      refute ProxyConfig.matches_cidr?("192.168.1.1", "2001:db8::/32")
      refute ProxyConfig.matches_cidr?("10.0.0.1", "fe80::/10")
    end

    test "should_bypass returns true when host matches NO_PROXY" do
      no_proxy = ["localhost", "*.internal.com", "192.168.0.0/16"]

      assert ProxyConfig.should_bypass?("localhost", no_proxy)
      assert ProxyConfig.should_bypass?("api.internal.com", no_proxy)
      assert ProxyConfig.should_bypass?("192.168.1.50", no_proxy)
      refute ProxyConfig.should_bypass?("external.example.com", no_proxy)
    end
  end

  describe "get_proxy_for_url" do
    setup do
      # Store original config
      original_proxy = Application.get_env(:tymeslot, :http_proxy)

      on_exit(fn ->
        # Restore original config
        if original_proxy do
          Application.put_env(:tymeslot, :http_proxy, original_proxy)
        else
          Application.delete_env(:tymeslot, :http_proxy)
        end
      end)

      :ok
    end

    test "returns nil when no proxy configured" do
      Application.delete_env(:tymeslot, :http_proxy)

      assert ProxyConfig.get_proxy_for_url("https://example.com") == nil
    end

    test "returns HTTPS proxy for https:// URLs" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: %{
          host: "http-proxy.example.com",
          port: 3128,
          auth: nil,
          url: "http://http-proxy.example.com:3128"
        },
        https_proxy: %{
          host: "https-proxy.example.com",
          port: 3129,
          auth: nil,
          url: "http://https-proxy.example.com:3129"
        },
        no_proxy: []
      })

      proxy = ProxyConfig.get_proxy_for_url("https://api.example.com/v1")
      assert proxy.host == "https-proxy.example.com"
      assert proxy.port == 3129
    end

    test "returns HTTP proxy for http:// URLs" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: %{
          host: "http-proxy.example.com",
          port: 3128,
          auth: nil,
          url: "http://http-proxy.example.com:3128"
        },
        https_proxy: %{
          host: "https-proxy.example.com",
          port: 3129,
          auth: nil,
          url: "http://https-proxy.example.com:3129"
        },
        no_proxy: []
      })

      proxy = ProxyConfig.get_proxy_for_url("http://api.example.com/v1")
      assert proxy.host == "http-proxy.example.com"
      assert proxy.port == 3128
    end

    test "returns nil when URL host matches NO_PROXY" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 3128,
          auth: nil,
          url: "http://proxy.example.com:3128"
        },
        no_proxy: ["localhost", "*.internal.com"]
      })

      assert ProxyConfig.get_proxy_for_url("https://api.internal.com/v1") == nil
      assert ProxyConfig.get_proxy_for_url("https://localhost:4000") == nil
    end

    test "falls back to HTTPS proxy when only HTTPS proxy is configured" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 3128,
          auth: nil,
          url: "http://proxy.example.com:3128"
        },
        no_proxy: []
      })

      proxy = ProxyConfig.get_proxy_for_url("http://api.example.com/v1")
      assert proxy.host == "proxy.example.com"
    end
  end

  describe "build_req_proxy_options" do
    test "returns empty list when no proxy" do
      assert ProxyConfig.build_req_proxy_options(nil) == []
    end

    test "builds proxy options without auth" do
      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: nil,
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config)

      assert options[:connect_options][:proxy] == {:http, "proxy.example.com", 3128, []}
    end

    test "builds proxy options with auth - CRITICAL STRUCTURE for Mint.TunnelProxy" do
      # This test verifies the fix for proxy authentication bug.
      # proxy_headers MUST be at connect_options level, NOT in proxy tuple.
      # Placing headers in tuple causes 407 errors because Mint.TunnelProxy
      # doesn't send them during CONNECT handshake.

      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: {"user", "pass"},
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config)

      # CRITICAL: Verify proxy tuple has NO OPTIONS (4th element must be [])
      # If this fails, proxy auth won't work - headers must be at connect_options level
      {scheme, host, port, proxy_tuple_opts} = options[:connect_options][:proxy]
      assert scheme == :http
      assert host == "proxy.example.com"
      assert port == 3128

      assert proxy_tuple_opts == [],
             "Proxy tuple options MUST be empty. Headers belong at connect_options level!"

      # CRITICAL: Verify proxy_headers is at connect_options level
      # If this fails, authentication will fail with 407
      connect_opts = options[:connect_options]

      assert Keyword.has_key?(connect_opts, :proxy_headers),
             "proxy_headers MUST exist at connect_options level for CONNECT tunnel auth"

      proxy_headers = connect_opts[:proxy_headers]
      assert is_list(proxy_headers), "proxy_headers must be a list"
      assert length(proxy_headers) == 1, "Should have exactly one auth header"

      # Verify header format
      [{"Proxy-Authorization", auth_header}] = proxy_headers
      assert String.starts_with?(auth_header, "Basic ")

      # Verify correct base64 encoding
      expected_auth = Base.encode64("user:pass")
      assert auth_header == "Basic #{expected_auth}"
    end

    test "proxy_headers must NOT be in proxy tuple (regression test)" do
      # This test explicitly catches the bug we fixed.
      # If someone accidentally puts proxy_headers back in the tuple,
      # this test will fail.

      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: {"user", "pass"},
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config)
      {_scheme, _host, _port, proxy_tuple_opts} = options[:connect_options][:proxy]

      # MUST NOT have proxy_headers in tuple
      refute Keyword.has_key?(proxy_tuple_opts, :proxy_headers),
             "BUG: proxy_headers found in proxy tuple! This breaks authentication. " <>
               "Move proxy_headers to connect_options level."
    end

    test "complete structure matches Req/Mint expectations" do
      # This test verifies the EXACT structure that Req/Mint expects.
      # If Req/Mint changes their API, this test will catch it.

      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: {"testuser", "testpass"},
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config)

      # Expected structure for Req with authenticated proxy:
      expected = [
        connect_options: [
          proxy: {:http, "proxy.example.com", 3128, []},
          proxy_headers: [
            {"Proxy-Authorization", "Basic " <> Base.encode64("testuser:testpass")}
          ]
        ]
      ]

      assert options == expected,
             "Structure mismatch! Expected structure that works with Req/Mint. " <>
               "If this fails, proxy authentication will break."
    end

    test "HTTPS proxy scheme is preserved" do
      proxy_config = %{
        host: "secure-proxy.example.com",
        port: 8443,
        auth: {"user", "pass"},
        scheme: "https"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config)
      {scheme, _host, _port, _opts} = options[:connect_options][:proxy]

      assert scheme == :https
    end

    test "special characters in credentials are properly encoded" do
      # Test that special characters in username/password work correctly
      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: {"user@domain", "p@ss:word!"},
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config)
      [{"Proxy-Authorization", auth_header}] = options[:connect_options][:proxy_headers]

      # Verify it's properly base64 encoded
      expected = "Basic " <> Base.encode64("user@domain:p@ss:word!")
      assert auth_header == expected
    end
  end
end
