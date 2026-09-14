defmodule Tymeslot.Infrastructure.ProxyConfigTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.{ProxyConfig, ProxyCredentials}

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
      assert ProxyConfig.build_req_proxy_options(nil, "https://api.example.com") == []
    end

    test "builds proxy options without auth" do
      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: nil,
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config, "http://api.example.com")

      assert options[:connect_options][:proxy] ==
               {:http, "proxy.example.com", 3128, [mode: :passive]}
    end

    test "builds proxy options with auth - CRITICAL STRUCTURE for Mint.TunnelProxy" do
      # This test verifies the fix for proxy authentication bug.
      # proxy_headers MUST be at connect_options level, NOT in proxy tuple.
      # Placing headers in tuple causes 407 errors because Mint.TunnelProxy
      # doesn't send them during CONNECT handshake.

      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: ProxyCredentials.new({"user", "pass"}),
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config, "http://api.example.com")

      # CRITICAL: the tuple's 4th element carries connection options ONLY.
      # proxy_headers in here causes 407s — they must be at connect_options level.
      # The options themselves depend on the *target's* scheme, deliberately:
      # see ProxyConfig.build_req_proxy_options/2 and the behavioural coverage in
      # ProxySocketOptionsTest. This one is an http:// target.
      {scheme, host, port, proxy_tuple_opts} = options[:connect_options][:proxy]
      assert scheme == :http
      assert host == "proxy.example.com"
      assert port == 3128

      assert proxy_tuple_opts == [mode: :passive],
             "Proxy tuple must carry the connection mode and nothing else. " <>
               "Headers belong at connect_options level!"

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

    test "complete structure matches Req/Mint expectations" do
      # This test verifies the EXACT structure that Req/Mint expects.
      # If Req/Mint changes their API, this test will catch it.

      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: ProxyCredentials.new({"testuser", "testpass"}),
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config, "http://api.example.com")

      # Expected structure for Req with an authenticated proxy and an http:// target:
      expected = [
        connect_options: [
          proxy: {:http, "proxy.example.com", 3128, [mode: :passive]},
          proxy_headers: [
            {"Proxy-Authorization", "Basic " <> Base.encode64("testuser:testpass")}
          ],
          timeout: 10_000
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
        auth: ProxyCredentials.new({"user", "pass"}),
        scheme: "https"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config, "https://api.example.com")
      {scheme, _host, _port, _opts} = options[:connect_options][:proxy]

      assert scheme == :https
    end

    test "the proxy socket options differ by target scheme, on purpose" do
      # These two must not converge. Mint proxies http:// through
      # Mint.UnsafeProxy, which hands the socket straight to Finch and so needs
      # it passive, and https:// through Mint.TunnelProxy, which speaks CONNECT
      # over it first by waiting on socket messages and so needs it active.
      # Giving both `mode: :passive` is what broke every proxied https:// request
      # in 1.15.3 (issue #97). ProxySocketOptionsTest proves the consequence;
      # this pins the contract.
      proxy_config = %{host: "proxy.example.com", port: 3128, auth: nil, scheme: "http"}

      {_scheme, _host, _port, http_opts} =
        ProxyConfig.build_req_proxy_options(proxy_config, "http://api.example.com")[
          :connect_options
        ][:proxy]

      {_scheme, _host, _port, https_opts} =
        ProxyConfig.build_req_proxy_options(proxy_config, "https://api.example.com")[
          :connect_options
        ][:proxy]

      assert http_opts[:mode] == :passive
      refute Keyword.has_key?(https_opts, :mode)
    end

    test "special characters in credentials are properly encoded" do
      # Test that special characters in username/password work correctly
      proxy_config = %{
        host: "proxy.example.com",
        port: 3128,
        auth: ProxyCredentials.new({"user@domain", "p@ss:word!"}),
        scheme: "http"
      }

      options = ProxyConfig.build_req_proxy_options(proxy_config, "https://api.example.com")
      [{"Proxy-Authorization", auth_header}] = options[:connect_options][:proxy_headers]

      # Verify it's properly base64 encoded
      expected = "Basic " <> Base.encode64("user@domain:p@ss:word!")
      assert auth_header == expected
    end
  end

  describe "from_env/1" do
    test "is nil when no proxy variable is set" do
      assert ProxyConfig.from_env(%{"NO_PROXY" => "localhost"}) == nil
    end

    test "prefers uppercase variables and parses NO_PROXY into patterns" do
      config =
        ProxyConfig.from_env(%{
          "HTTPS_PROXY" => "http://upper.example.com:3128",
          "https_proxy" => "http://lower.example.com:3128",
          "no_proxy" => " localhost, ,*.internal.example.com "
        })

      assert config.http_proxy == nil

      assert %{host: "upper.example.com", port: 3128, scheme: "http", auth: nil} =
               config.https_proxy

      assert config.no_proxy == ["localhost", "*.internal.example.com"]
    end

    test "decodes userinfo into credentials, allowing an empty password" do
      config =
        ProxyConfig.from_env(%{
          "HTTP_PROXY" => "http://user%40corp:p%3Ass@proxy.example.com",
          "HTTPS_PROXY" => "http://only-user@proxy.example.com"
        })

      # `URI.parse/1` fills in the scheme's default port.
      assert config.http_proxy.port == 80

      assert config.http_proxy.auth ==
               %ProxyCredentials{username: "user@corp", password: "p:ss"}

      assert config.https_proxy.auth == %ProxyCredentials{username: "only-user", password: ""}
    end

    test "raises on a proxy URL without a host" do
      assert_raise RuntimeError, ~r/valid host/, fn ->
        ProxyConfig.from_env(%{"HTTPS_PROXY" => "not a url"})
      end
    end
  end

  describe "proxy credentials are not printable" do
    setup do
      original_proxy = Application.get_env(:tymeslot, :http_proxy)

      on_exit(fn ->
        if original_proxy do
          Application.put_env(:tymeslot, :http_proxy, original_proxy)
        else
          Application.delete_env(:tymeslot, :http_proxy)
        end
      end)

      :ok
    end

    # Every redaction this codebase has is keyed: `MetadataRedactor` scrubs
    # sensitive *keys*, `Logging.Redactor` anchors every pattern on a key name
    # or scheme word, and `@derive {Inspect, except: […]}` masks a named field.
    # The proxy password used to sit in the second position of a tuple, where
    # it had no key for any of them to match, so anything that inspected a
    # proxy config — an exception message, a `dbg/1`, an OTP crash report
    # printing a task's arguments — printed it in the clear.
    test "the password never appears in inspect/1 output of a loaded config" do
      Application.put_env(:tymeslot, :http_proxy, runtime_shaped_config())

      config = ProxyConfig.load()

      refute inspect(config, limit: :infinity) =~ "hunter2"
      refute inspect(config.https_proxy, limit: :infinity) =~ "hunter2"
      refute inspect(config.https_proxy.auth, limit: :infinity) =~ "hunter2"

      # The username is diagnostic, not secret, and masking it would cost the
      # one detail that tells two configured proxies apart.
      assert inspect(config.https_proxy.auth) =~ "dav-user"
    end

    # The credential still has to *work*: a conversion that dropped the header
    # would make every proxied request fail with a 407, with nothing in the logs
    # to say why.
    #
    # This pins the structure; `ProxySocketOptionsTest` proves the same
    # structure reaches a real proxy socket on the CONNECT request.
    test "a runtime.exs-shaped config still produces the Proxy-Authorization header" do
      Application.put_env(:tymeslot, :http_proxy, runtime_shaped_config())

      proxy = ProxyConfig.get_proxy_for_url("https://api.example.com/v1")
      assert proxy.host == "proxy.example.com"
      assert proxy.port == 3128

      options = ProxyConfig.build_req_proxy_options(proxy, "https://api.example.com/v1")

      assert options[:connect_options][:proxy_headers] == [
               {"Proxy-Authorization", "Basic " <> Base.encode64("dav-user:hunter2")}
             ]
    end

    # What `config/runtime.exs` stores is what `Application.get_all_env/1`, an
    # observer or a remote console prints, so the password has to be masked
    # there already, not only once `load/0` has run.
    test "the password never appears when the application environment is inspected" do
      Application.put_env(:tymeslot, :http_proxy, runtime_shaped_config())

      refute inspect(Application.get_all_env(:tymeslot), limit: :infinity) =~ "hunter2"
    end

    test "load/0 still converts credentials configured as a raw tuple" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 3128,
          auth: {"dav-user", "hunter2"},
          scheme: "http"
        },
        no_proxy: []
      })

      assert ProxyConfig.load().https_proxy.auth ==
               %ProxyCredentials{username: "dav-user", password: "hunter2"}
    end

    test "a proxy URL with no userinfo still yields a working unauthenticated proxy" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: parse_proxy_url("http://proxy.example.com:3128"),
        no_proxy: []
      })

      proxy = ProxyConfig.get_proxy_for_url("https://api.example.com/v1")
      assert proxy.auth == nil

      options = ProxyConfig.build_req_proxy_options(proxy, "https://api.example.com/v1")
      refute Keyword.has_key?(options[:connect_options], :proxy_headers)
    end

    # A raw tuple must not fall through to "no credentials": that failure is
    # silent where it happens and only surfaces as a 407 much later.
    #
    # The tuple is fetched back out of the application environment rather than
    # written inline because the `@spec` already excludes it, and Elixir's type
    # checker rejects the literal call before the runtime guard can be reached.
    # That is the static half of the same protection; this pins the dynamic half.
    test "build_req_proxy_options/2 refuses a credential that skipped the boundary" do
      Application.put_env(:tymeslot, :unconverted_test_credentials, {"dav-user", "hunter2"})
      on_exit(fn -> Application.delete_env(:tymeslot, :unconverted_test_credentials) end)

      unconverted = %{
        host: "proxy.example.com",
        port: 3128,
        auth: Application.get_env(:tymeslot, :unconverted_test_credentials),
        scheme: "http"
      }

      assert_raise ArgumentError, ~r/raw tuple/, fn ->
        ProxyConfig.build_req_proxy_options(unconverted, "https://api.example.com/v1")
      end
    end

    defp runtime_shaped_config do
      ProxyConfig.from_env(%{"HTTPS_PROXY" => "http://dav-user:hunter2@proxy.example.com:3128"})
    end

    defp parse_proxy_url(proxy_url) do
      ProxyConfig.from_env(%{"HTTPS_PROXY" => proxy_url}).https_proxy
    end
  end
end
