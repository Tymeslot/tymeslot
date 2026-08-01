defmodule Tymeslot.Infrastructure.ProxyIntegrationTest do
  use ExUnit.Case, async: false

  alias Tymeslot.Infrastructure.{HTTPClient, ProxyConfig, ProxyVerifier}

  @moduletag :integration
  @moduletag timeout: 30_000

  # This test requires real proxy credentials to be configured
  # Run with: mix test --only integration
  # Or: HTTPS_PROXY=http://user:pass@proxy:port mix test test/tymeslot/infrastructure/proxy_integration_test.exs

  setup_all do
    # Save original proxy config
    original_proxy = Application.get_env(:tymeslot, :http_proxy)

    # Check if proxy is configured via environment or application config
    proxy_configured? =
      (System.get_env("HTTPS_PROXY") || System.get_env("HTTP_PROXY") || original_proxy) != nil

    on_exit(fn ->
      if original_proxy do
        Application.put_env(:tymeslot, :http_proxy, original_proxy)
      else
        Application.delete_env(:tymeslot, :http_proxy)
      end
    end)

    %{proxy_configured?: proxy_configured?, original_proxy: original_proxy}
  end

  describe "proxy integration" do
    test "makes request through configured proxy", %{proxy_configured?: proxy_configured?} do
      unless proxy_configured? do
        IO.puts("\n⚠️  Skipping integration test - no proxy configured")
        IO.puts("   Set HTTPS_PROXY environment variable to run this test")

        IO.puts(
          "   Example: HTTPS_PROXY=http://user:pass@proxy:port mix test --only integration\n"
        )
      end

      # Skip test if no proxy configured
      if proxy_configured? do
        # Test URL that returns origin IP
        test_url = "https://httpbin.org/ip"

        IO.puts("\n=== Proxy Integration Test ===")
        IO.puts("Testing proxy with: #{test_url}")

        case HTTPClient.get(test_url) do
          {:ok, response} ->
            assert response.status == 200, "Expected 200 status, got #{response.status}"

            # Parse response to get origin IP
            case Jason.decode(response.body) do
              {:ok, %{"origin" => origin_ip}} ->
                IO.puts("✓ Success! Request routed through proxy")
                IO.puts("  Origin IP: #{origin_ip}")
                IO.puts("  (This is the proxy's external IP address)")

                # If we got here, proxy is working
                assert String.match?(origin_ip, ~r/^\d+\.\d+\.\d+\.\d+$/),
                       "Expected valid IP address format"

              {:error, _error} ->
                flunk("Failed to parse JSON response from httpbin")
            end

          {:error, error} ->
            flunk("Proxy request failed: #{inspect(error)}")
        end
      end
    end

    test "proxy authentication works with real credentials", %{
      proxy_configured?: proxy_configured?
    } do
      if proxy_configured? do
        # This test verifies that proxy authentication is actually working
        # by making a request that requires CONNECT tunneling (HTTPS through HTTP proxy)

        IO.puts("\n=== Testing Proxy Authentication (CONNECT tunnel) ===")

        # Use HTTPS URL to force CONNECT tunnel
        test_url = "https://httpbin.org/status/200"

        response = HTTPClient.get(test_url)

        case response do
          {:ok, %{status: 407}} ->
            flunk(
              "Proxy authentication failed (407). " <>
                "Check credentials or verify proxy_headers is at connect_options level"
            )

          {:error, error} ->
            flunk("Request failed: #{inspect(error)}")

          _other ->
            :ok
        end

        # A 200 over HTTPS proves the CONNECT tunnel was established and the
        # Proxy-Authorization header was accepted.
        assert {:ok, %{status: 200}} = response
      end
    end

    test "NO_PROXY bypass works correctly", %{
      proxy_configured?: proxy_configured?,
      original_proxy: original_proxy
    } do
      if proxy_configured? do
        IO.puts("\n=== Testing NO_PROXY Bypass ===")

        # Configure NO_PROXY to bypass httpbin.org
        Application.put_env(:tymeslot, :http_proxy, %{
          http_proxy: nil,
          https_proxy: %{
            host: "proxy.example.com",
            port: 8080,
            auth: {"user", "pass"},
            scheme: "http"
          },
          no_proxy: ["httpbin.org", "*.httpbin.org"]
        })

        # This request should NOT use proxy
        proxy = ProxyConfig.get_proxy_for_url("https://httpbin.org/ip")
        assert proxy == nil, "httpbin.org should be bypassed (in NO_PROXY list)"

        IO.puts("✓ NO_PROXY bypass verified")

        # Restore original config
        if original_proxy do
          Application.put_env(:tymeslot, :http_proxy, original_proxy)
        end
      end
    end

    test "proxy works with different request methods", %{proxy_configured?: proxy_configured?} do
      if proxy_configured? do
        IO.puts("\n=== Testing Multiple HTTP Methods Through Proxy ===")

        # Test GET
        {:ok, get_response} = HTTPClient.get("https://httpbin.org/get")
        assert get_response.status == 200
        IO.puts("✓ GET request through proxy: success")

        # Test POST
        {:ok, post_response} =
          HTTPClient.post(
            "https://httpbin.org/post",
            Jason.encode!(%{test: "data"}),
            [{"content-type", "application/json"}]
          )

        assert post_response.status == 200
        IO.puts("✓ POST request through proxy: success")

        # Test HEAD
        {:ok, head_response} = HTTPClient.head("https://httpbin.org/status/200")
        assert head_response.status == 200
        IO.puts("✓ HEAD request through proxy: success")
      end
    end

    test "proxy handles connection errors gracefully", %{proxy_configured?: proxy_configured?} do
      if proxy_configured? do
        IO.puts("\n=== Testing Error Handling ===")

        # Override with invalid proxy
        Application.put_env(:tymeslot, :http_proxy, %{
          http_proxy: nil,
          https_proxy: %{
            host: "invalid-proxy-that-does-not-exist.local",
            port: 9999,
            auth: nil,
            scheme: "http"
          },
          no_proxy: []
        })

        # Request should fail gracefully
        result = HTTPClient.get("https://httpbin.org/ip", [], timeout: 5_000)
        assert match?({:error, _}, result), "Expected error for unreachable proxy"
        IO.puts("✓ Error handling verified")
      end
    end
  end

  describe "proxy verifier integration" do
    test "verify command succeeds with real proxy", %{proxy_configured?: proxy_configured?} do
      if proxy_configured? do
        IO.puts("\n=== Testing ProxyVerifier ===")

        result = ProxyVerifier.verify(timeout: 10_000)

        assert result.proxy_configured == true,
               "Proxy should be configured"

        assert result.proxy_reachable == true,
               "Proxy should be reachable. Got errors: #{inspect(result.errors)}"

        assert result.traffic_flows_through_proxy == true,
               "Traffic should flow through proxy. Got errors: #{inspect(result.errors)}"

        assert result.errors == [], "Should have no errors, got: #{inspect(result.errors)}"

        IO.puts("✓ ProxyVerifier integration test passed")
        IO.puts("  Proxy: #{result.details[:proxy_used]}")
        IO.puts("  Origin IP: #{result.details[:origin_ip]}")
      end
    end
  end
end
