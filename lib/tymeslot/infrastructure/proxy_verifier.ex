defmodule Tymeslot.Infrastructure.ProxyVerifier do
  @moduledoc """
  Verifies that HTTP proxy configuration is working correctly.

  Provides diagnostic tools to:
  - Test basic proxy connectivity
  - Verify traffic is actually routed through the proxy
  - Detect common misconfigurations

  ## How Verification Works

  Uses an external HTTP testing service (default: httpbin.org/ip) to verify that:
  1. The proxy is reachable
  2. Traffic actually flows through the proxy
  3. Authentication (if configured) works correctly

  The service returns the origin IP address the request arrived from. That
  address is the whole verification: a request that reaches the destination
  proves only that the destination is reachable, since a configuration bug that
  drops the proxy connects directly and returns the same 200. So the test URL
  is fetched twice, once through the proxy and once with it deliberately
  bypassed, and traffic is reported as flowing through the proxy only when the
  two origins differ. On a deployment whose firewall permits nothing but the
  proxy the direct fetch fails outright, which is proof of the same thing.

  ## Security Considerations

  **Test URL Selection:**
  - Default test URL uses httpbin.org, a trusted public HTTP testing service
  - In high-security environments, use the `test_url` option with an internal endpoint
  - Test URLs should use HTTPS to prevent credential exposure during verification
  - For air-gapped deployments, configure an internal test endpoint

  **Custom Test Endpoints:**

  Set a default in config:

      config :tymeslot, :proxy_verification_url, "https://your-internal-test.example.com/ip"

  Or specify per-verification:

      ProxyVerifier.verify(test_url: "https://internal-test.corp.com")

  **Accepted Test URL Requirements:**
  - Must use HTTPS scheme (HTTP is rejected to prevent credential leakage)
  - Must have a valid hostname
  - Should return a 2xx status code for successful verification
  """

  require Logger
  alias Tymeslot.Infrastructure.{HTTPClient, ProxyConfig}

  @type verification_result :: %{
          proxy_configured: boolean(),
          proxy_reachable: boolean(),
          traffic_flows_through_proxy: boolean(),
          errors: [String.t()],
          details: map()
        }

  @doc """
  Performs a comprehensive proxy verification.

  Tests:
  1. Proxy configuration is loaded
  2. Proxy is reachable
  3. Traffic actually flows through the proxy, by comparing the origin the test
     URL reports through the proxy against the one it reports directly

  Options:
  - `:test_url` - URL to test proxy with (default: httpbin.org/ip, must be HTTPS)
  - `:timeout` - Request timeout in ms (default: 10000, range: 1000-300000)

  ## Examples

      # Use default settings
      ProxyVerifier.verify()

      # Custom test URL (must be HTTPS)
      ProxyVerifier.verify(test_url: "https://internal-test.corp.com/ip")

      # Custom timeout
      ProxyVerifier.verify(timeout: 30_000)

  ## Errors

  Raises `ArgumentError` if:
  - Test URL is not HTTPS (to prevent credential leakage)
  - Test URL is malformed
  - Timeout is outside acceptable range (1000-300000ms)
  """
  @spec verify(keyword()) :: verification_result()
  def verify(opts \\ []) do
    test_url = Keyword.get(opts, :test_url, "https://httpbin.org/ip")
    timeout = Keyword.get(opts, :timeout, 10_000)

    # Validate inputs
    with :ok <- validate_test_url(test_url),
         :ok <- validate_timeout(timeout) do
      run_verification(test_url, timeout)
    else
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp run_verification(test_url, timeout) do
    Logger.info("Starting proxy verification test...")

    result = %{
      proxy_configured: false,
      proxy_reachable: false,
      traffic_flows_through_proxy: false,
      errors: [],
      details: %{}
    }

    # Step 1: Check if proxy is configured
    case ProxyConfig.load() do
      nil ->
        %{result | errors: ["No proxy configured (HTTP_PROXY/HTTPS_PROXY not set)"]}

      config ->
        result = %{result | proxy_configured: true, details: %{config: sanitize_config(config)}}
        Logger.info("Proxy configured", proxy: format_proxy_info(config))

        # Step 2: Test proxy connectivity and traffic flow
        test_proxy_connectivity(config, test_url, timeout, result)
    end
  end

  @doc """
  Quick check if proxy is configured and appears reachable.
  Less comprehensive than verify/1 but faster.
  """
  @spec quick_check() :: :ok | {:error, String.t()}
  def quick_check do
    case ProxyConfig.load() do
      nil ->
        {:error, "No proxy configured"}

      config ->
        Logger.debug("Proxy configured", proxy: format_proxy_info(config))

        # Try a simple HTTP request with short timeout
        case test_request("https://httpbin.org/status/200", timeout: 5_000) do
          {:ok, %{status: 200}} ->
            Logger.info("Proxy quick check: SUCCESS - received response through proxy")
            :ok

          {:ok, %{status: status}} ->
            {:error, "Proxy reachable but returned unexpected status: #{status}"}

          {:error, error} ->
            error_msg = format_error_message(error)
            {:error, "Proxy request failed: #{error_msg}"}
        end
    end
  end

  # Private Functions

  defp test_proxy_connectivity(config, test_url, timeout, result) do
    # Determine which proxy to use based on test URL
    proxy = ProxyConfig.get_proxy_for_url(test_url)

    case proxy do
      nil ->
        if should_bypass_proxy?(test_url, config) do
          error = "Test URL #{test_url} is in NO_PROXY list - cannot verify proxy"
          Logger.warning(error)
          %{result | errors: [error | result.errors]}
        else
          error = "Proxy configured but not selected for test URL #{test_url}"
          Logger.error(error)
          %{result | errors: [error | result.errors]}
        end

      proxy_config ->
        Logger.info("Testing proxy connectivity",
          proxy: "#{proxy_config.host}:#{proxy_config.port}"
        )

        test_with_proxy(proxy_config, test_url, timeout, result)
    end
  end

  defp test_with_proxy(proxy_config, test_url, timeout, result) do
    # Make request through HTTPClient which will use the proxy
    case test_request(test_url, timeout: timeout) do
      {:ok, response} ->
        handle_successful_response(response, proxy_config, test_url, timeout, result)

      {:error, error} ->
        error_msg = format_error_message(error)
        error_text = "Proxy request failed: #{error_msg}"
        Logger.error(error_text)

        %{
          result
          | errors: [error_text | result.errors],
            details:
              Map.merge(result.details, %{
                request_error: error_msg,
                test_url: test_url,
                proxy_used: "#{proxy_config.host}:#{proxy_config.port}"
              })
        }
    end
  end

  defp handle_successful_response(response, proxy_config, test_url, timeout, result) do
    if response.status in 200..299 do
      Logger.info("Proxy connectivity verified", status: response.status)

      result = %{
        result
        | proxy_reachable: true,
          details:
            Map.merge(result.details, %{
              status: response.status,
              test_url: test_url,
              proxy_used: "#{proxy_config.host}:#{proxy_config.port}"
            })
      }

      confirm_traffic_flows(response, test_url, timeout, result)
    else
      error = "Proxy reachable but returned status #{response.status}"
      Logger.warning(error)

      %{
        result
        | proxy_reachable: true,
          errors: [error | result.errors],
          details:
            Map.merge(result.details, %{
              status: response.status,
              body_preview: preview_body(response.body)
            })
      }
    end
  end

  # Reaching the destination is not evidence that the proxy carried the
  # request. A bug that drops the proxy options connects directly and still
  # returns 200, so a check that stopped at the status would report a green
  # `traffic_flows_through_proxy` for exactly the misconfiguration it exists to
  # find. The one thing that separates the two cases is the address the
  # destination saw the request arrive from, so the same URL is fetched again
  # with the proxy deliberately bypassed and the two origins compared.
  defp confirm_traffic_flows(response, test_url, timeout, result) do
    case read_origin(response.body) do
      {:ok, proxied_origin} ->
        Logger.info("Request origin IP verified", origin_ip: proxied_origin)

        result = %{result | details: Map.put(result.details, :origin_ip, proxied_origin)}
        compare_against_direct(proxied_origin, test_url, timeout, result)

      :error ->
        add_error(
          result,
          "Reached #{test_url} through the proxy, but its response carries no origin " <>
            "IP address, so there is no way to tell the request apart from a direct one. " <>
            "Point :proxy_verification_url at an endpoint that echoes the caller's address."
        )
    end
  end

  defp compare_against_direct(proxied_origin, test_url, timeout, result) do
    case direct_origin(test_url, timeout) do
      {:ok, ^proxied_origin} ->
        add_error(
          result,
          "Traffic is NOT flowing through the proxy: #{test_url} reports the same origin " <>
            "(#{proxied_origin}) with the proxy configured as it does with the proxy " <>
            "bypassed, so the proxy settings are being dropped before the connection."
        )

      {:ok, direct_origin} ->
        %{
          result
          | traffic_flows_through_proxy: true,
            details: Map.put(result.details, :direct_origin_ip, direct_origin)
        }

      # Nothing left this machine directly, so the proxy is the only route out
      # and the successful proxied request is itself the proof. This is the
      # normal answer on a deployment whose egress firewall permits the proxy
      # and nothing else.
      :unreachable ->
        %{
          result
          | traffic_flows_through_proxy: true,
            details: Map.put(result.details, :direct_egress, :unreachable)
        }

      :error ->
        add_error(
          result,
          "Reached #{test_url} through the proxy, but the direct request used to compare " <>
            "against carries no origin IP address, so the comparison proves nothing."
        )
    end
  end

  # Only a transport error counts as "this machine has no direct route out".
  # A non-2xx does not: the destination answering us directly at all means the
  # request left, and it may simply be rate-limiting or blocking this address
  # while serving the proxy's. Confirming the proxy on that basis would be the
  # false green this whole comparison exists to remove.
  defp direct_origin(test_url, timeout) do
    case test_request(test_url, timeout: timeout, bypass_proxy: true) do
      {:ok, %{status: status} = response} when status in 200..299 -> read_origin(response.body)
      {:ok, _non_success} -> :error
      {:error, _reason} -> :unreachable
    end
  end

  # Two shapes of "which address did this arrive from" endpoint: httpbin's
  # `{"origin": "…"}` JSON, and the bare single-line address that icanhazip and
  # most internal equivalents return.
  # The size bound comes first: a body larger than this is not an origin
  # endpoint's answer whatever else it is, and neither `Jason.decode/1` nor
  # `String.split/2` should be handed a response that could be tens of
  # megabytes just to discover that.
  defp read_origin(body) when is_binary(body) and byte_size(body) <= 4096 do
    case Jason.decode(body) do
      {:ok, %{"origin" => origin}} when is_binary(origin) -> parse_origin(origin)
      _no_origin_field -> parse_origin(body)
    end
  end

  defp read_origin(_body), do: :error

  # httpbin reports a comma-separated chain when the request passed through
  # more than one hop; the first entry is where the chain started. The length
  # bound is what keeps an arbitrary response body out of `parse_address/1`:
  # 45 characters is the longest an IPv6 address can be.
  defp parse_origin(origin) do
    candidate = origin |> String.split(",") |> List.first() |> String.trim()

    with true <- byte_size(candidate) <= 45,
         {:ok, _address} <- :inet.parse_address(String.to_charlist(candidate)) do
      {:ok, candidate}
    else
      _not_an_address -> :error
    end
  end

  defp add_error(result, error) do
    Logger.warning(error)
    %{result | errors: [error | result.errors]}
  end

  defp test_request(url, opts) do
    HTTPClient.get(url, [], opts)
  end

  defp should_bypass_proxy?(url, config) do
    uri = URI.parse(url)
    ProxyConfig.should_bypass?(uri.host, config.no_proxy)
  end

  defp format_proxy_info(config) do
    parts = []

    parts =
      if config.http_proxy do
        ["HTTP=#{format_proxy_endpoint(config.http_proxy)}" | parts]
      else
        parts
      end

    parts =
      if config.https_proxy do
        ["HTTPS=#{format_proxy_endpoint(config.https_proxy)}" | parts]
      else
        parts
      end

    parts =
      if config.no_proxy != [] do
        ["NO_PROXY=#{Enum.join(config.no_proxy, ",")}" | parts]
      else
        parts
      end

    Enum.join(parts, ", ")
  end

  defp format_proxy_endpoint(proxy) do
    auth_indicator = if proxy.auth, do: "[auth]", else: ""
    "#{proxy.scheme}://#{auth_indicator}#{proxy.host}:#{proxy.port}"
  end

  defp sanitize_config(config) do
    %{
      http_proxy: sanitize_proxy(config.http_proxy),
      https_proxy: sanitize_proxy(config.https_proxy),
      no_proxy: config.no_proxy
    }
  end

  defp sanitize_proxy(nil), do: nil

  defp sanitize_proxy(proxy) do
    %{
      host: proxy.host,
      port: proxy.port,
      scheme: proxy.scheme,
      auth: if(proxy.auth, do: "configured", else: nil)
    }
  end

  defp preview_body(body) when is_binary(body) do
    String.slice(body, 0, 200)
  end

  defp preview_body(_body), do: nil

  defp format_error_message(%{__struct__: struct_name} = error) do
    case Map.fetch(error, :reason) do
      {:ok, reason} -> "#{inspect(struct_name)}: #{inspect(reason)}"
      :error -> "#{inspect(struct_name)}: #{inspect(error)}"
    end
  end

  # Input validation

  @doc false
  defp validate_test_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        :ok

      %URI{scheme: "http"} ->
        {:error,
         "Test URL must use HTTPS (not HTTP). " <>
           "Using HTTP could expose proxy credentials during verification. " <>
           "Use https:// instead."}

      %URI{scheme: nil} ->
        {:error, "Test URL must include a scheme (https://). Got: #{url}"}

      %URI{host: nil} ->
        {:error, "Test URL must include a hostname. Got: #{url}"}

      _uri ->
        {:error, "Invalid test URL format. Must be https://hostname/path. Got: #{url}"}
    end
  end

  defp validate_test_url(_url), do: {:error, "Test URL must be a string"}

  @doc false
  defp validate_timeout(timeout) when is_integer(timeout) do
    cond do
      timeout < 1_000 ->
        {:error, "Timeout too short (minimum: 1000ms). Got: #{timeout}ms"}

      timeout > 300_000 ->
        {:error, "Timeout too long (maximum: 300000ms / 5 minutes). Got: #{timeout}ms"}

      true ->
        :ok
    end
  end

  defp validate_timeout(_timeout), do: {:error, "Timeout must be an integer (milliseconds)"}
end
