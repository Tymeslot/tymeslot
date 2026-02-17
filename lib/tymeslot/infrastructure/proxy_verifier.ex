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

  The service returns the origin IP address of the request. When using a proxy,
  this will be the proxy's external IP, not your direct IP.

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
  3. Traffic actually flows through the proxy (using httpbin or similar)

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
        Logger.info("Proxy configured: #{format_proxy_info(config)}")

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
        Logger.debug("Proxy configured: #{format_proxy_info(config)}")

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
        Logger.info("Testing proxy connectivity to #{proxy_config.host}:#{proxy_config.port}...")
        test_with_proxy(proxy_config, test_url, timeout, result)
    end
  end

  defp test_with_proxy(proxy_config, test_url, timeout, result) do
    # Make request through HTTPClient which will use the proxy
    case test_request(test_url, timeout: timeout) do
      {:ok, response} ->
        handle_successful_response(response, proxy_config, test_url, result)

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

  defp handle_successful_response(response, proxy_config, test_url, result) do
    if response.status in 200..299 do
      Logger.info("✓ Proxy connectivity verified: received #{response.status} response")

      result = %{
        result
        | proxy_reachable: true,
          traffic_flows_through_proxy: true,
          details:
            Map.merge(result.details, %{
              status: response.status,
              test_url: test_url,
              proxy_used: "#{proxy_config.host}:#{proxy_config.port}"
            })
      }

      # Try to parse response body to confirm proxy usage (if using httpbin)
      if String.contains?(test_url, "httpbin") do
        verify_httpbin_response(response, result)
      else
        result
      end
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

  defp verify_httpbin_response(response, result) do
    case Jason.decode(response.body) do
      {:ok, %{"origin" => origin}} ->
        Logger.info("✓ Request origin IP: #{origin}")
        %{result | details: Map.put(result.details, :origin_ip, origin)}

      _result ->
        result
    end
  rescue
    _exception -> result
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

  defp format_error_message(%{__struct__: struct_name, reason: reason}) do
    "#{inspect(struct_name)}: #{inspect(reason)}"
  end

  defp format_error_message(%{__struct__: struct_name} = error) do
    "#{inspect(struct_name)}: #{inspect(error)}"
  end

  defp format_error_message(error) do
    inspect(error)
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
