defmodule Tymeslot.Security.UrlValidation do
  @moduledoc """
  Shared HTTP/HTTPS URL validation helpers for security-sensitive inputs.
  """

  alias Tymeslot.Security.{PrivateIPv4, PrivateIPv6}

  @default_invalid_message "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"
  @default_max_length 2_000
  @default_scheme_error "Only HTTP and HTTPS URLs are allowed"
  @default_https_error "Use HTTPS for non-local servers"
  @default_private_ip_error "Private or local network addresses are not allowed"
  @disallowed_protocols ["javascript:", "data:", "file:", "ftp:"]

  @spec validate_http_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_http_url(url, opts \\ [])

  def validate_http_url(url, opts) when is_binary(url) do
    invalid_message = Keyword.get(opts, :invalid_message, @default_invalid_message)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, authority: authority}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        case authority_host(authority, host) do
          {:ok, real_host} -> validate_url_checks(url, scheme, real_host, opts)
          :error -> {:error, invalid_message}
        end

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
    max_length = Keyword.get(opts, :max_length, @default_max_length)

    length_error =
      Keyword.get(opts, :length_error_message, default_length_error(max_length))

    disallowed_protocol_error =
      Keyword.get(opts, :disallowed_protocol_error, @default_scheme_error)

    https_error_message = Keyword.get(opts, :https_error_message, @default_https_error)
    private_ip_error = Keyword.get(opts, :private_ip_error_message, @default_private_ip_error)
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

  defp default_length_error(max_length), do: "URL must be #{max_length} characters or less"

  defp contains_disallowed_substring?(url, disallowed_protocols) do
    Enum.any?(disallowed_protocols, &String.contains?(url, &1))
  end

  # `URI.parse/1` mangles IPv6 authorities: it truncates `[fe80::1%eth0]` to
  # the host "fe80" and reads the `::1` of an unbracketed `fe80::1` as a port.
  # Either way the private-address checks below would never see the real
  # address, so the host is re-derived from the raw authority instead.
  defp authority_host(authority, _host) when is_binary(authority) do
    authority
    |> strip_userinfo()
    |> host_from_authority()
  end

  defp authority_host(_authority, host), do: {:ok, host}

  # The host cannot contain "@", so userinfo runs up to the last one.
  defp strip_userinfo(authority) do
    authority |> String.split("@") |> List.last()
  end

  # RFC 3986 reserves the bracketed form for IP literals. Anything bracketed
  # that is not a parseable IPv6 address is rejected rather than guessed at.
  defp host_from_authority("[" <> rest) do
    with [literal, port] when literal != "" <- String.split(rest, "]", parts: 2),
         true <- valid_port_suffix?(port),
         true <- ipv6_literal?(literal) do
      {:ok, literal}
    else
      _unparseable -> :error
    end
  end

  defp host_from_authority(authority) do
    case String.split(authority, ":") do
      [host] when host != "" -> {:ok, host}
      [host, port] when host != "" -> if valid_port_suffix?(port), do: {:ok, host}, else: :error
      # Several colons without brackets is not a valid authority. An
      # unbracketed IPv6 literal lands here; reject it rather than guess.
      _ambiguous -> :error
    end
  end

  defp valid_port_suffix?(""), do: true
  defp valid_port_suffix?(":" <> port), do: valid_port_suffix?(port)
  defp valid_port_suffix?(port), do: Regex.match?(~r/^\d+$/, port)

  defp ipv6_literal?(literal) do
    case parse_ipv6(literal) do
      {:ok, _tuple} -> true
      :error -> false
    end
  end

  # Strips the zone ID (`fe80::1%eth0`, or its RFC 6874 `%25eth0` encoding)
  # before parsing, since `:inet` does not accept one.
  defp parse_ipv6(literal) do
    bare = literal |> String.split("%") |> hd()

    case :inet.parse_strict_address(to_charlist(bare)) do
      {:ok, tuple} when tuple_size(tuple) == 8 -> {:ok, tuple}
      _other -> :error
    end
  end

  defp run_extra_checks(nil, _context), do: :ok

  defp run_extra_checks(fun, context) when is_function(fun, 1), do: fun.(context)

  defp local_or_private_host?(host) do
    host = String.downcase(host)

    cond do
      host == "localhost" -> true
      zoned_host?(host) -> true
      ambiguous_numeric_host?(host) -> true
      ipv4_tuple_private?(host) -> true
      ipv6_local_or_private?(host) -> true
      true -> false
    end
  end

  # A zone ID scopes an address to a single local interface, so a zoned
  # literal is never publicly routable — not even when the address itself
  # sits outside the private ranges.
  defp zoned_host?(host) do
    case String.split(host, "%", parts: 2) do
      [_unzoned] -> false
      [address, _zone] -> match?({:ok, _tuple}, parse_ipv6(address))
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
    case parse_ipv6(host) do
      {:ok, tuple} ->
        PrivateIPv6.private?(tuple)

      :error ->
        # Not a parseable IPv6 literal — it's a domain name; let DNS resolution handle it
        false
    end
  end
end
