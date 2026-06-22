defmodule Tymeslot.Security.UrlValidation do
  @moduledoc """
  Shared HTTP/HTTPS URL validation helpers for security-sensitive inputs.
  """

  alias Tymeslot.Security.{PrivateIPv4, PrivateIPv6}

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
    host = String.downcase(host)

    cond do
      host == "localhost" -> true
      ambiguous_numeric_host?(host) -> true
      ipv4_tuple_private?(host) -> true
      ipv6_local_or_private?(host) -> true
      true -> false
    end
  end

  # Parse canonical dotted IPv4 via Erlang and check numerically.
  # Catches 127.0.0.1, 10.0.0.0, etc. even when they aren't caught by a
  # string prefix (e.g., 0.0.0.0 bound to all interfaces).
  defp ipv4_tuple_private?(host) do
    case :inet.parse_strict_address(to_charlist(host)) do
      {:ok, {_a, _b, _c, _d} = tuple} -> PrivateIPv4.private?(tuple)
      _other -> false
    end
  end

  # Non-canonical numeric hostnames are resolved inconsistently by HTTP
  # clients — 2130706433, 0x7f000001, 0177.0.0.1, and 127.1 all reach
  # 127.0.0.1 in most stacks. We cannot know what each client will do,
  # so treat any numeric-looking host that isn't canonical dotted IPv4
  # as unsafe under block_private_ips.
  defp ambiguous_numeric_host?(host) do
    cond do
      # Pure decimal integer (e.g. 2130706433).
      Regex.match?(~r/^\d+$/, host) -> true
      # Hex segment anywhere (e.g. 0x7f000001 or 0x7f.0x0.0x0.0x1).
      Regex.match?(~r/(^|\.)0x/i, host) -> true
      # Octal leading zero with dots (e.g. 0177.0.0.1).
      Regex.match?(~r/^0\d+\./, host) -> true
      # Dotted shorthand with fewer than 4 all-numeric parts (e.g. 127.1).
      numeric_shorthand?(host) -> true
      true -> false
    end
  end

  defp numeric_shorthand?(host) do
    parts = String.split(host, ".")

    length(parts) in [2, 3] and
      Enum.all?(parts, &Regex.match?(~r/^\d+$/, &1))
  end

  defp ipv6_local_or_private?(host) do
    # host is already lowercased by local_or_private_host?/1.
    # Strip brackets (e.g. [::1] → ::1) and zone ID (e.g. fe80::1%eth0 → fe80::1).
    bare =
      host
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split("%")
      |> hd()

    case :inet.parse_strict_address(to_charlist(bare)) do
      {:ok, tuple} when tuple_size(tuple) == 8 ->
        PrivateIPv6.private?(tuple)

      {:ok, _tuple} ->
        false

      {:error, _reason} ->
        # Not a parseable IPv6 literal — it's a domain name; let DNS resolution handle it
        false
    end
  end
end
