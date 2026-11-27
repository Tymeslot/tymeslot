defmodule Tymeslot.Security.DnsResolutionBehaviour do
  @moduledoc """
  Behaviour for DNS-based SSRF protection, allowing the resolver to be
  substituted in tests.

  Every check fails closed, but a hostname that resolves to no address at all
  is reported as `{:error, {:unresolved, reason}}` rather than as a refusal.
  With no address there was nothing to judge, typically because DNS is down
  or the name is mistyped, so callers report it as the connection failure the
  request would otherwise have hit, and retry it as one.
  """

  @typedoc "No address resolved; `reason` is the resolver's, such as `:nxdomain`."
  @type unresolved :: {:unresolved, term()}

  @callback check_private_ip(String.t(), keyword()) ::
              :ok | {:error, String.t() | unresolved()}

  @doc """
  Same check as `check_private_ip/2`, but returns the addresses it approved so
  the caller can connect to one of them instead of resolving a second time.

  Optional: a resolver that does not implement it simply cannot be pinned to,
  and its callers fall back to validating by hostname alone. Test doubles are
  the expected case.
  """
  @callback resolve_public(String.t(), keyword()) ::
              {:ok, [:inet.ip_address()]} | {:error, String.t() | unresolved()}

  @doc """
  The inverse check, for a request that is only allowed because its host is
  meant to be on a private network: returns every address the hostname
  resolves to when all of them are private, loopback or link-local, and an
  error when any is public or nothing resolves.

  Optional: a resolver that does not implement it cannot confirm that a name
  is internal, so the requests that depend on the confirmation are refused.
  """
  @callback resolve_internal(String.t(), keyword()) ::
              {:ok, [:inet.ip_address()]} | {:error, String.t() | unresolved()}

  @optional_callbacks resolve_public: 2, resolve_internal: 2
end

defmodule Tymeslot.Security.DnsResolution do
  @moduledoc """
  DNS-resolving SSRF protection for server-side HTTP requests.

  Resolves a URL's hostname via `:inet.getaddrs/2` (plural) for both IPv4 and
  IPv6, and rejects the URL if **any** of the returned addresses falls within a
  private, loopback, link-local, or unspecified range.  Using the plural form
  closes the multi-record variant of DNS-based SSRF: an attacker cannot hide a
  private address behind a round-robin set that includes a public address.

  A hostname that resolves to nothing is `{:error, {:unresolved, reason}}`,
  not a refusal; see `Tymeslot.Security.DnsResolutionBehaviour`.

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

  alias Tymeslot.Security.{DnsResolutionBehaviour, PrivateIPv4, PrivateIPv6}

  @default_error "URL resolves to a private or local network address"
  @public_address_error "Plain http to an internal name must resolve to a private network address"

  @impl DnsResolutionBehaviour
  @spec check_private_ip(String.t(), keyword()) ::
          :ok | {:error, String.t() | DnsResolutionBehaviour.unresolved()}
  def check_private_ip(url, opts) do
    case resolve_public(url, opts) do
      {:ok, _addresses} -> :ok
      {:error, reason} -> {:error, reason}
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
  @impl DnsResolutionBehaviour
  @spec resolve_public(String.t(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, String.t() | DnsResolutionBehaviour.unresolved()}
  def resolve_public(url, opts) do
    error_message = Keyword.get(opts, :error_message, @default_error)

    case URI.parse(url).host do
      nil -> {:error, error_message}
      "" -> {:error, error_message}
      host -> resolve_and_check(to_charlist(host), error_message)
    end
  end

  @doc """
  Resolves `url`'s hostname and returns every address, IPv4 first, only when
  all of them are private, loopback or link-local.

  Used for plain-http requests to a name accepted as internal by its shape
  alone (a single label a resolver search domain can complete to a public
  name, or `.lan`, which nothing reserves): the request carries credentials in
  clear text, so it may only go ahead when the name really stays on the
  private network.
  """
  @impl DnsResolutionBehaviour
  @spec resolve_internal(String.t(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, String.t() | DnsResolutionBehaviour.unresolved()}
  def resolve_internal(url, opts) do
    error_message = Keyword.get(opts, :error_message, @public_address_error)

    with host when is_binary(host) and host != "" <- URI.parse(url).host,
         {:ok, ipv4_addrs, ipv6_addrs} <- lookup(to_charlist(host)),
         true <-
           Enum.all?(ipv4_addrs, &PrivateIPv4.private?/1) and
             Enum.all?(ipv6_addrs, &PrivateIPv6.private?/1) do
      {:ok, ipv4_addrs ++ ipv6_addrs}
    else
      {:error, {:unresolved, _reason}} = unresolved -> unresolved
      _public_or_no_host -> {:error, error_message}
    end
  end

  defp resolve_and_check(host_charlist, error_message) do
    with {:ok, ipv4_addrs, ipv6_addrs} <- lookup(host_charlist) do
      if Enum.any?(ipv4_addrs, &PrivateIPv4.private?/1) or
           Enum.any?(ipv6_addrs, &PrivateIPv6.private?/1),
         do: {:error, error_message},
         else: {:ok, ipv4_addrs ++ ipv6_addrs}
    end
  end

  # Every A and AAAA record, or why the name gave neither. getaddrs/2 (plural)
  # returns all records of a family; getaddr/2 returns one and could miss a
  # private address hidden in a multi-record response. One family failing is
  # normal (a host with no AAAA record), so only both failing is a failed
  # lookup, reported with the IPv4 reason.
  defp lookup(host_charlist) do
    ipv4 = :inet.getaddrs(host_charlist, :inet)
    ipv6 = :inet.getaddrs(host_charlist, :inet6)

    case {addresses(ipv4), addresses(ipv6)} do
      {[], []} -> {:error, {:unresolved, failure_reason(ipv4)}}
      {ipv4_addrs, ipv6_addrs} -> {:ok, ipv4_addrs, ipv6_addrs}
    end
  end

  defp addresses({:ok, addrs}), do: addrs
  defp addresses({:error, _reason}), do: []

  defp failure_reason({:error, reason}), do: reason
  defp failure_reason({:ok, []}), do: :nxdomain
end
