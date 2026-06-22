defmodule Tymeslot.Security.DnsResolutionBehaviour do
  @moduledoc """
  Behaviour for DNS-based SSRF protection, allowing the resolver to be
  substituted in tests.
  """

  @callback check_private_ip(String.t(), keyword()) :: :ok | {:error, String.t()}
end

defmodule Tymeslot.Security.DnsResolution do
  @moduledoc """
  DNS-resolving SSRF protection for server-side HTTP requests.

  Resolves a URL's hostname via `:inet.getaddrs/2` (plural) for both IPv4 and
  IPv6, and rejects the URL if **any** of the returned addresses falls within a
  private, loopback, link-local, or unspecified range.  Using the plural form
  closes the multi-record variant of DNS-based SSRF: an attacker cannot hide a
  private address behind a round-robin set that includes a public address.

  Note: a residual TOCTOU window exists between this check and the TCP connect
  performed by Finch, which re-resolves DNS independently.  This matches the
  posture of `Tymeslot.Webhooks.SsrfValidator`.  True connection-IP pinning
  would require a custom Mint/Finch transport and is deferred.

  For string-based (non-resolving) private IP checks at changeset time,
  use `Tymeslot.Security.UrlValidation` with `block_private_ips: true`.
  """

  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  alias Tymeslot.Security.{PrivateIPv4, PrivateIPv6}

  @default_error "URL resolves to a private or local network address"

  @impl Tymeslot.Security.DnsResolutionBehaviour
  @spec check_private_ip(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_private_ip(url, opts \\ []) do
    error_message = Keyword.get(opts, :error_message, @default_error)

    case URI.parse(url).host do
      nil -> {:error, error_message}
      "" -> {:error, error_message}
      host -> resolve_and_check(to_charlist(host), error_message)
    end
  end

  # Resolve via both families and reject if any returned address is private.
  # Using getaddrs/2 (plural) ensures all A/AAAA records are inspected —
  # a single getaddr/2 call only returns one record and could miss a private
  # address hidden in a multi-record response.
  defp resolve_and_check(host_charlist, error_message) do
    ipv4_addrs = getaddrs(host_charlist, :inet)
    ipv6_addrs = getaddrs(host_charlist, :inet6)

    cond do
      Enum.any?(ipv4_addrs, &PrivateIPv4.private?/1) ->
        {:error, error_message}

      Enum.any?(ipv6_addrs, &PrivateIPv6.private?/1) ->
        {:error, error_message}

      ipv4_addrs == [] and ipv6_addrs == [] ->
        {:error, error_message}

      true ->
        :ok
    end
  end

  # Returns all resolved addresses for the given family, or [] on failure.
  defp getaddrs(host_charlist, family) do
    case :inet.getaddrs(host_charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _reason} -> []
    end
  end
end
