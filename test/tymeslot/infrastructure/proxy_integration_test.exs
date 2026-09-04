defmodule Tymeslot.Infrastructure.ProxyIntegrationTest.Availability do
  @moduledoc false

  @doc """
  Whether this run has an outbound proxy to exercise.
  """
  @spec proxy_configured?() :: boolean()
  def proxy_configured? do
    (System.get_env("HTTPS_PROXY") || System.get_env("HTTP_PROXY") ||
       Application.get_env(:tymeslot, :http_proxy)) != nil
  end

  @doc """
  The extra module tag `ProxyIntegrationTest` carries, which is a `:skip` when
  the suite cannot run.

  `--only <tag>` overrides ExUnit's default exclusions, so naming any other tag
  this module declares — `--only infrastructure`, which the verification skill
  documents as a way to run a domain — drags it into a run that never asked for
  it and where `setup_all` finds no proxy. Skipping is the honest answer there:
  nothing was checked, and the summary line says so rather than reporting a
  pass. A run that names `:proxy_integration` itself still reaches the loud
  failure in `setup_all`, because somebody asking for this check and quietly
  not getting it is the one outcome worth failing over.
  """
  @spec moduletag() :: keyword()
  def moduletag do
    if proxy_configured?() or requested?() do
      []
    else
      [skip: "no proxy configured (HTTPS_PROXY/HTTP_PROXY)"]
    end
  end

  # `--only proxy_integration` yields a bare atom, `--include proxy_integration`
  # a `{tag, value}` pair; both mean the run asked for this suite by name.
  defp requested? do
    ExUnit.configuration()
    |> Keyword.get(:include, [])
    |> Enum.any?(&(&1 == :proxy_integration or match?({:proxy_integration, _value}, &1)))
  end
end

defmodule Tymeslot.Infrastructure.ProxyIntegrationTest do
  @moduledoc """
  Exercises the HTTP client against a **real** outbound proxy and the public
  internet, so it is opt-in: `:proxy_integration` is excluded by default (see
  `Tymeslot.Test.SuiteConfig`).

  Run it with a proxy configured, otherwise `setup_all` fails loudly:

      HTTPS_PROXY=http://user:pass@proxy:port mix test --only proxy_integration

  A run that reaches this module through one of its other tags rather than by
  naming `:proxy_integration` skips it instead of failing; see
  `Tymeslot.Infrastructure.ProxyIntegrationTest.Availability`.
  """
  use ExUnit.Case, async: false

  alias Tymeslot.Infrastructure.{HTTPClient, ProxyConfig, ProxyVerifier}
  alias Tymeslot.Infrastructure.ProxyIntegrationTest.Availability

  @moduletag Availability.moduletag()
  @moduletag :proxy_integration
  @moduletag :integration
  @moduletag timeout: 30_000
  @moduletag :infrastructure

  @origin_url "https://httpbin.org/ip"

  setup_all do
    original_proxy = Application.get_env(:tymeslot, :http_proxy)

    unless Availability.proxy_configured?() do
      raise """
      No proxy configured, so these tests cannot assert anything.

      Configure one and re-run, e.g.:

          HTTPS_PROXY=http://user:pass@proxy:port mix test --only proxy_integration
      """
    end

    # The suite routes every unproxied request through a `Req.Test` plug, which
    # opens no socket. A proxied request already sidesteps it, but the direct
    # request these tests compare against does not, and a plug cannot report
    # the address this machine leaves from. This module is the one place that
    # wants the real transport in both directions.
    original_plug = Application.get_env(:tymeslot, :req_test_plug)
    Application.delete_env(:tymeslot, :req_test_plug)

    on_exit(fn ->
      restore_proxy(original_proxy)
      restore_plug(original_plug)
    end)

    %{original_proxy: original_proxy, direct_origin: direct_origin!()}
  end

  # The address this machine leaves from with the proxy bypassed. Measuring it
  # is what separates "the request reached httpbin" from "the request reached
  # httpbin through the proxy": a direct request returns 200 and an IP-shaped
  # origin too, so every assertion that stops at the shape of the answer holds
  # just as well when the proxy is being dropped before the connection. Failing
  # here rather than skipping is deliberate, for the same reason the missing
  # proxy above fails: a suite that cannot tell the two apart must not report
  # that it checked.
  defp direct_origin! do
    case HTTPClient.get(@origin_url, [], bypass_proxy: true) do
      {:ok, %{status: 200, body: body}} ->
        origin_of!(body)

      other ->
        raise """
        Could not reach #{@origin_url} with the proxy bypassed, so there is no
        direct origin to compare the proxied one against and these tests cannot
        tell a proxied request from a direct one.

        Got: #{inspect(other)}
        """
    end
  end

  defp origin_of!(body) do
    case Jason.decode(body) do
      {:ok, %{"origin" => origin}} when is_binary(origin) ->
        origin |> String.split(",") |> List.first() |> String.trim()

      _no_origin ->
        raise "No origin IP in the response from #{@origin_url}: #{inspect(body)}"
    end
  end

  setup %{original_proxy: original_proxy} do
    # Several tests override :http_proxy; restore it per test so they cannot
    # leak an invalid proxy into whichever test runs next.
    on_exit(fn -> restore_proxy(original_proxy) end)
    :ok
  end

  describe "proxy integration" do
    test "makes request through configured proxy", %{direct_origin: direct_origin} do
      assert {:ok, response} = HTTPClient.get(@origin_url)
      assert response.status == 200

      proxied_origin = origin_of!(response.body)

      # The destination saw the proxy's address, not this machine's. Asserting
      # the origin merely looks like an IP address would hold for a request
      # that never touched the proxy at all.
      assert proxied_origin != direct_origin,
             "Request was not proxied: httpbin reports the same origin " <>
               "(#{proxied_origin}) with the proxy configured as it does with " <>
               "the proxy bypassed."
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
    test "verify command succeeds with real proxy", %{direct_origin: direct_origin} do
      result = ProxyVerifier.verify(timeout: 10_000)

      assert result.proxy_configured == true, "Proxy should be configured"

      assert result.proxy_reachable == true,
             "Proxy should be reachable. Got errors: #{inspect(result.errors)}"

      assert result.traffic_flows_through_proxy == true,
             "Traffic should flow through proxy. Got errors: #{inspect(result.errors)}"

      assert result.errors == [], "Should have no errors, got: #{inspect(result.errors)}"

      # The claim above is only worth anything because the verifier reached
      # that verdict by comparing the two origins rather than by seeing a 200.
      assert result.details.direct_origin_ip == direct_origin
      assert result.details.origin_ip != direct_origin
    end
  end

  defp restore_proxy(nil), do: Application.delete_env(:tymeslot, :http_proxy)
  defp restore_proxy(proxy), do: Application.put_env(:tymeslot, :http_proxy, proxy)

  defp restore_plug(nil), do: Application.delete_env(:tymeslot, :req_test_plug)
  defp restore_plug(plug), do: Application.put_env(:tymeslot, :req_test_plug, plug)
end
