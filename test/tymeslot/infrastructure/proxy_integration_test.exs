defmodule Tymeslot.Infrastructure.ProxyIntegrationTest do
  @moduledoc """
  Exercises the HTTP client against a **real** outbound proxy and the public
  internet, so it is opt-in: `:proxy_integration` is excluded by default (see
  `Tymeslot.Test.SuiteConfig`).

  Run it with a proxy configured, otherwise `setup_all` fails loudly:

      HTTPS_PROXY=http://user:pass@proxy:port mix test --only proxy_integration
  """
  use ExUnit.Case, async: false

  alias Tymeslot.Infrastructure.{HTTPClient, ProxyConfig, ProxyVerifier}

  @moduletag :proxy_integration
  @moduletag :integration
  @moduletag timeout: 30_000

  setup_all do
    original_proxy = Application.get_env(:tymeslot, :http_proxy)

    proxy_configured? =
      (System.get_env("HTTPS_PROXY") || System.get_env("HTTP_PROXY") || original_proxy) != nil

    unless proxy_configured? do
      raise """
      No proxy configured, so these tests cannot assert anything.

      Configure one and re-run, e.g.:

          HTTPS_PROXY=http://user:pass@proxy:port mix test --only proxy_integration
      """
    end

    on_exit(fn -> restore_proxy(original_proxy) end)

    %{original_proxy: original_proxy}
  end

  setup %{original_proxy: original_proxy} do
    # Several tests override :http_proxy; restore it per test so they cannot
    # leak an invalid proxy into whichever test runs next.
    on_exit(fn -> restore_proxy(original_proxy) end)
    :ok
  end

  describe "proxy integration" do
    test "makes request through configured proxy" do
      assert {:ok, response} = HTTPClient.get("https://httpbin.org/ip")
      assert response.status == 200

      assert {:ok, %{"origin" => origin_ip}} = Jason.decode(response.body)

      # The origin is the proxy's external address, not ours.
      assert String.match?(origin_ip, ~r/^\d+\.\d+\.\d+\.\d+$/),
             "Expected valid IP address format, got: #{inspect(origin_ip)}"
    end

    test "proxy authentication works with real credentials" do
      # An HTTPS URL forces a CONNECT tunnel: a 200 proves the tunnel was
      # established and the Proxy-Authorization header was accepted.
      response = HTTPClient.get("https://httpbin.org/status/200")

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

      assert {:ok, %{status: 200}} = response
    end

    test "NO_PROXY bypass works correctly" do
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

      assert ProxyConfig.get_proxy_for_url("https://httpbin.org/ip") == nil,
             "httpbin.org should be bypassed (in NO_PROXY list)"
    end

    test "proxy works with different request methods" do
      assert {:ok, get_response} = HTTPClient.get("https://httpbin.org/get")
      assert get_response.status == 200

      assert {:ok, post_response} =
               HTTPClient.post(
                 "https://httpbin.org/post",
                 Jason.encode!(%{test: "data"}),
                 [{"content-type", "application/json"}]
               )

      assert post_response.status == 200

      assert {:ok, head_response} = HTTPClient.head("https://httpbin.org/status/200")
      assert head_response.status == 200
    end

    test "proxy handles connection errors gracefully" do
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

      result = HTTPClient.get("https://httpbin.org/ip", [], timeout: 5_000)
      assert match?({:error, _error}, result), "Expected error for unreachable proxy"
    end
  end

  describe "proxy verifier integration" do
    test "verify command succeeds with real proxy" do
      result = ProxyVerifier.verify(timeout: 10_000)

      assert result.proxy_configured == true, "Proxy should be configured"

      assert result.proxy_reachable == true,
             "Proxy should be reachable. Got errors: #{inspect(result.errors)}"

      assert result.traffic_flows_through_proxy == true,
             "Traffic should flow through proxy. Got errors: #{inspect(result.errors)}"

      assert result.errors == [], "Should have no errors, got: #{inspect(result.errors)}"
    end
  end

  defp restore_proxy(nil), do: Application.delete_env(:tymeslot, :http_proxy)
  defp restore_proxy(proxy), do: Application.put_env(:tymeslot, :http_proxy, proxy)
end
