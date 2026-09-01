defmodule Tymeslot.Security.PrivateIPv6 do
  @moduledoc """
  Shared IPv6 private-range classification.

  Used by both `Tymeslot.Security.UrlValidation` (string-time SSRF check)
  and `Tymeslot.Security.DnsResolution` (request-time SSRF check) so that
  both layers agree on what counts as a private, loopback, link-local, or
  unspecified IPv6 address.

  IPv4-mapped (`::ffff:x.x.x.x`), IPv4-compatible (`::x.x.x.x`), NAT64
  (`64:ff9b::/96`), 6to4 (`2002::/16`), and Teredo (`2001:0::/32`) addresses
  embed an IPv4 address; all five are decoded and delegated to
  `PrivateIPv4.private?/1` so the two modules stay in sync.

  Ranges covered:
  - `::` — unspecified address (RFC 4291)
  - `::1` — loopback (RFC 4291)
  - `::ffff:0:0/96` — IPv4-mapped (RFC 4291), classified via `PrivateIPv4`
  - `::0.0.0.0/96` — IPv4-compatible, deprecated (RFC 4291), classified via
    `PrivateIPv4`
  - `64:ff9b::/96` — NAT64 well-known prefix (RFC 6052), classified via
    `PrivateIPv4`
  - `2002::/16` — 6to4 (RFC 3056), the embedded IPv4 sits in bits 16-47,
    classified via `PrivateIPv4`
  - `2001:0::/32` — Teredo (RFC 4380), the client's IPv4 sits in the last two
    hextets, obfuscated with a bitwise NOT, classified via `PrivateIPv4`
  - `fe80::/10` — link-local unicast (RFC 4291)
  - `fec0::/10` — site-local unicast, deprecated (RFC 4291, RFC 3879)
  - `fc00::/7` — unique local unicast (RFC 4193)
  - `ff00::/8` — multicast (RFC 4291)
  """

  import Bitwise, only: [band: 2, bsr: 2, bxor: 2]

  alias Tymeslot.Security.PrivateIPv4

  @doc """
  Returns true when the 8-element IPv6 tuple falls in a private, loopback,
  link-local, multicast, unspecified, or IPv4-embedded-private range.
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

  # 64:ff9b::x.x.x.x — NAT64 well-known prefix; classify the embedded IPv4 address
  def private?({0x0064, 0xFF9B, 0, 0, 0, 0, hi, lo}) do
    PrivateIPv4.private?(decode_ipv4(hi, lo))
  end

  # ::x.x.x.x — IPv4-compatible, deprecated; classify the embedded IPv4 address
  def private?({0, 0, 0, 0, 0, 0, hi, lo}) do
    PrivateIPv4.private?(decode_ipv4(hi, lo))
  end

  # 2002::/16 — 6to4; the embedded IPv4 address is bits 16-47 (the second and
  # third hextets)
  def private?({0x2002, hi, lo, _s4, _s5, _s6, _s7, _s8}) do
    PrivateIPv4.private?(decode_ipv4(hi, lo))
  end

  # 2001:0::/32 — Teredo; the client's IPv4 address occupies the last two
  # hextets, obfuscated with a bitwise NOT (RFC 4380 §4)
  def private?({0x2001, 0x0000, _server_hi, _server_lo, _flags, _obf_port, hi, lo}) do
    PrivateIPv4.private?(decode_ipv4(bxor(hi, 0xFFFF), bxor(lo, 0xFFFF)))
  end

  # fe80::/10 — link-local (first hextet 0xFE80..0xFEBF)
  def private?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8})
      when band(s1, 0xFFC0) == 0xFE80,
      do: true

  # fec0::/10 — site-local, deprecated (first hextet 0xFEC0..0xFEFF)
  def private?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8})
      when band(s1, 0xFFC0) == 0xFEC0,
      do: true

  # fc00::/7 — unique local (first hextet 0xFC00..0xFDFF)
  def private?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8})
      when band(s1, 0xFE00) == 0xFC00,
      do: true

  # ff00::/8 — multicast (first hextet 0xFF00..0xFFFF)
  def private?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8})
      when band(s1, 0xFF00) == 0xFF00,
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
  def unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: decode_ipv4(hi, lo)
  def unmap(address), do: address

  # Splits the two trailing 16-bit hextets of an IPv4-embedded IPv6 address
  # (mapped, compatible, or NAT64) into the equivalent 4-element IPv4 tuple.
  @spec decode_ipv4(0..0xFFFF, 0..0xFFFF) :: :inet.ip4_address()
  defp decode_ipv4(hi, lo) do
    {bsr(hi, 8), band(hi, 0xFF), bsr(lo, 8), band(lo, 0xFF)}
  end
end
