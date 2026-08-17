defmodule Tymeslot.Security.PrivateIPv6 do
  @moduledoc """
  Shared IPv6 private-range classification.

  Used by both `Tymeslot.Security.UrlValidation` (string-time SSRF check)
  and `Tymeslot.Security.DnsResolution` (request-time SSRF check) so that
  both layers agree on what counts as a private, loopback, link-local, or
  unspecified IPv6 address.

  IPv4-mapped addresses (`::ffff:x.x.x.x`) are decoded and delegated to
  `PrivateIPv4.private?/1` so the two modules stay in sync.

  Ranges covered:
  - `::` — unspecified address (RFC 4291)
  - `::1` — loopback (RFC 4291)
  - `::ffff:0:0/96` — IPv4-mapped (RFC 4291), classified via `PrivateIPv4`
  - `fe80::/10` — link-local unicast (RFC 4291)
  - `fc00::/7` — unique local unicast (RFC 4193)
  """

  import Bitwise, only: [band: 2, bsr: 2]

  alias Tymeslot.Security.PrivateIPv4

  @doc """
  Returns true when the 8-element IPv6 tuple falls in a private, loopback,
  link-local, unspecified, or IPv4-mapped-private range.
  """
  @spec private?(:inet.ip6_address()) :: boolean()

  # :: — unspecified
  def private?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # ::1 — loopback
  def private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # ::ffff:x.x.x.x — IPv4-mapped; classify the embedded IPv4 address
  def private?({0, 0, 0, 0, 0, 0xFFFF, _hi, _lo} = address) do
    address |> unmap() |> PrivateIPv4.private?()
  end

  # fe80::/10 — link-local (first hextet 0xFE80..0xFEBF)
  def private?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8})
      when band(s1, 0xFFC0) == 0xFE80,
      do: true

  # fc00::/7 — unique local (first hextet 0xFC00..0xFDFF)
  def private?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8})
      when band(s1, 0xFE00) == 0xFC00,
      do: true

  def private?(_other), do: false

  @doc """
  Decodes an IPv4-mapped IPv6 address (`::ffff:x.x.x.x`) into its 4-element
  IPv4 tuple, returning any other address unchanged.

  A dual-stack listener reports an IPv4 peer in this mapped form, so callers
  that match on IPv4 ranges must normalise through this function first or
  their 4-element clauses silently never match.
  """
  @spec unmap(:inet.ip_address()) :: :inet.ip_address()
  def unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    {bsr(hi, 8), band(hi, 0xFF), bsr(lo, 8), band(lo, 0xFF)}
  end

  def unmap(address), do: address
end
