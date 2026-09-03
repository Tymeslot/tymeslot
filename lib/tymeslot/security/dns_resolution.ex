defmodule Tymeslot.Security.DnsResolutionBehaviour do
  @moduledoc """
  Behaviour for DNS-based SSRF protection, allowing the resolver to be
  substituted in tests.
  """

  @callback check_private_ip(String.t(), keyword()) :: :ok | {:error, String.t()}

  @doc """
  Same check as `check_private_ip/2`, but returns the addresses it approved so
  the caller can connect to one of them instead of resolving a second time.

  Optional: a resolver that does not implement it simply cannot be pinned to,
  and its callers fall back to validating by hostname alone. Test doubles are
  the expected case.
  """
  @callback resolve_public(String.t(), keyword()) ::
              {:ok, [:inet.ip_address()]} | {:error, String.t()}

  @optional_callbacks resolve_public: 2
end

defmodule Tymeslot.Security.DnsResolution do
  @moduledoc """
  DNS-resolving SSRF protection for server-side HTTP requests.

  Resolves a URL's hostname via `:inet.getaddrs/2` (plural) for both IPv4 and
  IPv6, and rejects the URL if **any** of the returned addresses falls within a
  private, loopback, link-local, or unspecified range.  Using the plural form
  closes the multi-record variant of DNS-based SSRF: an attacker cannot hide a
  private address behind a round-robin set that includes a public address.

  `resolve_public/2` returns the approved addresses so a caller can connect to
  one of them directly rather than letting Finch resolve the hostname a second
  time. That second resolution is the DNS-rebinding window: a short-TTL record
  can answer public here and loopback by the time the socket opens.
  `Tymeslot.Security.ConnectionPinning` turns those addresses into the
  request options that close it.

  For string-based (non-resolving) private IP checks at changeset time,
  use `Tymeslot.Security.UrlValidation` with `block_private_ips: true`.
  """

  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  alias Tymeslot.Security.{PrivateIPv4, PrivateIPv6}

  @default_error "URL resolves to a private or local network address"

  @impl Tymeslot.Security.DnsResolutionBehaviour
  @spec check_private_ip(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_private_ip(url, opts \\ []) do
    case resolve_public(url, opts) do
      {:ok, _addresses} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Resolves `url`'s hostname and returns every approved address, IPv4 first.

  Same verdict as `check_private_ip/2` — any private, loopback, link-local or
  unspecified address in the answer rejects the whole URL — but the addresses
  come back so the connection can be pinned to one of them. Resolving here and
  connecting there is what makes the check binding; resolving twice only makes
  it advisory.
  """
  @impl Tymeslot.Security.DnsResolutionBehaviour
  @spec resolve_public(String.t(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, String.t()}
  def resolve_public(url, opts \\ []) do
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
        {:ok, ipv4_addrs ++ ipv6_addrs}
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
