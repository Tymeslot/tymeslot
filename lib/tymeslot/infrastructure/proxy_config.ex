defmodule Tymeslot.Infrastructure.ProxyConfig do
  @moduledoc """
  Handles HTTP/HTTPS proxy configuration with NO_PROXY support.

  Supports standard environment variables:
  - HTTP_PROXY / http_proxy - Proxy for HTTP requests
  - HTTPS_PROXY / https_proxy - Proxy for HTTPS requests
  - NO_PROXY / no_proxy - Comma-separated list of hosts to bypass proxy

  NO_PROXY patterns:
  - Exact hostname: `internal.example.com`
  - Wildcard domain: `*.example.com` (matches any subdomain)
  - CIDR notation: `10.0.0.0/8`, `192.168.0.0/16`
  - Special: `*` (bypass proxy for all hosts)
  """

  @type proxy_config :: %{
          host: String.t(),
          port: integer(),
          auth: {String.t(), String.t()} | nil,
          scheme: String.t()
        }

  @type t :: %{
          http_proxy: proxy_config() | nil,
          https_proxy: proxy_config() | nil,
          no_proxy: [String.t()]
        }

  @doc """
  Loads proxy configuration from application environment.
  """
  @spec load() :: t() | nil
  def load do
    Application.get_env(:tymeslot, :http_proxy)
  end

  @doc """
  Determines the appropriate proxy for a given URL.
  Returns nil if proxy should be bypassed.
  """
  @spec get_proxy_for_url(String.t()) :: proxy_config() | nil
  def get_proxy_for_url(url) do
    config = load()

    if config == nil do
      nil
    else
      uri = URI.parse(url)

      cond do
        # Check if host should bypass proxy
        should_bypass?(uri.host, config.no_proxy) ->
          nil

        # Use HTTPS proxy for https:// URLs
        uri.scheme == "https" && config.https_proxy ->
          config.https_proxy

        # Use HTTP proxy for http:// URLs
        uri.scheme == "http" && config.http_proxy ->
          config.http_proxy

        # Fallback to HTTPS proxy if available (most common)
        config.https_proxy ->
          config.https_proxy

        # Fallback to HTTP proxy
        true ->
          config.http_proxy
      end
    end
  end

  @doc """
  Checks if a host should bypass the proxy based on NO_PROXY patterns.
  """
  @spec should_bypass?(String.t() | nil, [String.t()]) :: boolean()
  def should_bypass?(nil, _no_proxy), do: false
  def should_bypass?(_host, []), do: false

  def should_bypass?(host, no_proxy) do
    Enum.any?(no_proxy, fn pattern ->
      matches_no_proxy_pattern?(host, pattern)
    end)
  end

  @doc """
  Checks if a host matches a NO_PROXY pattern.
  """
  @spec matches_no_proxy_pattern?(String.t(), String.t()) :: boolean()
  def matches_no_proxy_pattern?(_host, "*"), do: true

  def matches_no_proxy_pattern?(host, pattern) do
    cond do
      # Wildcard domain pattern (*.example.com)
      String.starts_with?(pattern, "*.") ->
        domain = String.trim_leading(pattern, "*.")
        host == domain || String.ends_with?(host, "." <> domain)

      # CIDR notation (e.g., 10.0.0.0/8)
      String.contains?(pattern, "/") ->
        matches_cidr?(host, pattern)

      # Exact hostname match
      true ->
        host == pattern
    end
  end

  @doc """
  Checks if a host (IP or hostname) matches a CIDR pattern.
  """
  @spec matches_cidr?(String.t(), String.t()) :: boolean()
  def matches_cidr?(host, cidr_pattern) do
    with {:ok, ip} <- parse_ip_address(host),
         {:ok, network, prefix_len} <- parse_cidr(cidr_pattern) do
      ip_in_network?(ip, network, prefix_len)
    else
      _other -> false
    end
  end

  # Parse IP address from string
  defp parse_ip_address(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _reason} -> {:error, :invalid_ip}
    end
  end

  # Parse CIDR notation (e.g., "192.168.0.0/16")
  defp parse_cidr(cidr_string) do
    case String.split(cidr_string, "/") do
      [network_str, prefix_str] ->
        with {:ok, network} <- parse_ip_address(network_str),
             {prefix_len, ""} <- Integer.parse(prefix_str),
             :ok <- validate_prefix_length(network, prefix_len) do
          {:ok, network, prefix_len}
        else
          _other -> {:error, :invalid_cidr}
        end

      _other ->
        {:error, :invalid_cidr}
    end
  end

  # Validate that prefix length is appropriate for IP version
  defp validate_prefix_length({_a, _b, _c, _d}, prefix) when prefix >= 0 and prefix <= 32, do: :ok
  defp validate_prefix_length({_s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8}, prefix) when prefix >= 0 and prefix <= 128,
    do: :ok

  defp validate_prefix_length(_ip, _prefix), do: {:error, :invalid_prefix}

  # Check if IP is in network/prefix range
  defp ip_in_network?(ip, network, prefix_len) do
    # Validate IP versions match (both IPv4 or both IPv6)
    if tuple_size(ip) != tuple_size(network) do
      false
    else
      ip_bits = ip_to_bits(ip)
      network_bits = ip_to_bits(network)

      # Compare the first prefix_len bits
      <<ip_prefix::size(prefix_len), _rest_ip::bitstring>> = ip_bits
      <<network_prefix::size(prefix_len), _rest_net::bitstring>> = network_bits

      ip_prefix == network_prefix
    end
  end

  # Convert IP tuple to bitstring
  defp ip_to_bits({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_to_bits({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  @doc """
  Builds Req-compatible proxy options from proxy config.
  """
  @spec build_req_proxy_options(proxy_config() | nil) :: keyword()
  def build_req_proxy_options(nil), do: []

  def build_req_proxy_options(proxy_config) do
    scheme = parse_scheme(proxy_config.scheme)

    proxy_tuple =
      case proxy_config do
        %{auth: {user, password}, host: host, port: port} when is_binary(user) and user != "" ->
          auth_header = {"proxy-authorization", "Basic " <> Base.encode64("#{user}:#{password}")}
          {scheme, host, port, [proxy_headers: [auth_header]]}

        %{host: host, port: port} ->
          {scheme, host, port, []}
      end

    [connect_options: [proxy: proxy_tuple]]
  end

  defp parse_scheme("https"), do: :https
  defp parse_scheme(_arg), do: :http
end
