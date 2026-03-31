defmodule Tymeslot.Security.UrlValidation do
  @moduledoc """
  Shared HTTP/HTTPS URL validation helpers for security-sensitive inputs.
  """

  @default_invalid_message "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"
  @default_length_error "URL must be 2000 characters or less"
  @default_scheme_error "Only HTTP and HTTPS URLs are allowed"
  @default_https_error "Use HTTPS for non-local servers"
  @default_private_ip_error "Private or local network addresses are not allowed"
  @disallowed_protocols ["javascript:", "data:", "file:", "ftp:"]

  @spec validate_http_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_http_url(url, opts \\ [])

  def validate_http_url(url, opts) when is_binary(url) do
    invalid_message = Keyword.get(opts, :invalid_message, @default_invalid_message)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        validate_url_checks(url, scheme, host, opts)

      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        disallowed_protocol_error =
          Keyword.get(opts, :disallowed_protocol_error, @default_scheme_error)

        {:error, disallowed_protocol_error}

      _invalid_url ->
        {:error, invalid_message}
    end
  end

  def validate_http_url(_url, _opts), do: {:error, @default_invalid_message}

  defp validate_url_checks(url, scheme, host, opts) do
    length_error = Keyword.get(opts, :length_error_message, @default_length_error)

    disallowed_protocol_error =
      Keyword.get(opts, :disallowed_protocol_error, @default_scheme_error)

    https_error_message = Keyword.get(opts, :https_error_message, @default_https_error)
    private_ip_error = Keyword.get(opts, :private_ip_error_message, @default_private_ip_error)
    max_length = Keyword.get(opts, :max_length, 2_000)
    disallowed_protocols = Keyword.get(opts, :disallowed_protocols, @disallowed_protocols)
    enforce_https_for_public = Keyword.get(opts, :enforce_https_for_public, false)
    # Note: enforce_https only rejects HTTP for public hosts — localhost/private
    # IPs are exempt so that dev/test environments work without HTTPS.
    enforce_https = Keyword.get(opts, :enforce_https, enforce_https_for_public)
    block_private_ips = Keyword.get(opts, :block_private_ips, false)
    extra_checks = Keyword.get(opts, :extra_checks)

    cond do
      String.length(url) > max_length ->
        {:error, length_error}

      contains_disallowed_substring?(url, disallowed_protocols) ->
        {:error, disallowed_protocol_error}

      block_private_ips and local_or_private_host?(host) ->
        {:error, private_ip_error}

      enforce_https and scheme == "http" and not local_or_private_host?(host) ->
        {:error, https_error_message}

      true ->
        run_extra_checks(extra_checks, %{url: url, scheme: scheme, host: host})
    end
  end

  defp contains_disallowed_substring?(url, disallowed_protocols) do
    Enum.any?(disallowed_protocols, &String.contains?(url, &1))
  end

  defp run_extra_checks(nil, _context), do: :ok

  defp run_extra_checks(fun, context) when is_function(fun, 1), do: fun.(context)

  defp local_or_private_host?(host) do
    host == "localhost" or
      String.starts_with?(host, [
        "127.",
        "10.",
        "192.168.",
        "169.254.",
        "172.16.",
        "172.17.",
        "172.18.",
        "172.19.",
        "172.20.",
        "172.21.",
        "172.22.",
        "172.23.",
        "172.24.",
        "172.25.",
        "172.26.",
        "172.27.",
        "172.28.",
        "172.29.",
        "172.30.",
        "172.31."
      ]) or
      ipv6_local_or_private?(host)
  end

  defp ipv6_local_or_private?(host) do
    # Normalize to lowercase for case-insensitive comparison
    # This prevents SSRF bypass via uppercase IPv6 addresses (e.g., FE80::1)
    host_lower = String.downcase(host)

    # Strip zone ID if present (e.g., %eth0, %1)
    # Zone IDs are used for link-local addresses and indicate network interface
    host_without_zone = host_lower |> String.split("%") |> hd()

    # Check for IPv6 localhost and private ranges
    # ::1 (localhost), fe80::/10 (link-local), fc00::/7 (unique local)
    # Also check for IPv4-mapped IPv6 addresses (::ffff:x.x.x.x)
    cond do
      # IPv4-mapped IPv6 addresses (::ffff:x.x.x.x)
      # Critical: Prevents SSRF bypass via ::ffff:169.254.169.254 (AWS metadata)
      String.contains?(host_without_zone, "::ffff:") ->
        ipv4_mapped_is_private?(host_without_zone)

      # IPv6 localhost
      host_without_zone in ["::1", "[::1]"] ->
        true

      # IPv6 link-local (fe80::/10)
      String.starts_with?(host_without_zone, ["fe80:", "[fe80:"]) ->
        true

      # IPv6 unique local addresses (fc00::/7)
      # This includes fc00: through fdff:
      ipv6_unique_local?(host_without_zone) ->
        true

      true ->
        false
    end
  end

  defp ipv6_unique_local?(host) do
    # Unique local addresses are fc00::/7
    # This means the first 7 bits are 1111110, which includes:
    # - fc (11111100) - fc00: through fcff:
    # - fd (11111101) - fd00: through fdff:
    String.starts_with?(host, ["fc", "[fc", "fd", "[fd"])
  end

  defp ipv4_mapped_is_private?(host) do
    # Extract IPv4 address from ::ffff:x.x.x.x format
    # Handles both [::ffff:x.x.x.x] and ::ffff:x.x.x.x
    # Note: Regex matches format but doesn't validate octets are ≤255.
    # This is acceptable because Elixir's URI parser will reject invalid IPs,
    # and invalid addresses would fail connection anyway.
    case Regex.run(~r/::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/, host) do
      [_full_match, ipv4] ->
        # Check if the IPv4 part is localhost or private
        ipv4 == "127.0.0.1" or
          String.starts_with?(ipv4, [
            "127.",
            "10.",
            "192.168.",
            "169.254.",
            "172.16.",
            "172.17.",
            "172.18.",
            "172.19.",
            "172.20.",
            "172.21.",
            "172.22.",
            "172.23.",
            "172.24.",
            "172.25.",
            "172.26.",
            "172.27.",
            "172.28.",
            "172.29.",
            "172.30.",
            "172.31."
          ])

      _no_match ->
        false
    end
  end
end
