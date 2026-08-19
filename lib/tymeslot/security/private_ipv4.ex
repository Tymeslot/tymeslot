defmodule Tymeslot.Security.PrivateIPv4 do
  @moduledoc """
  Shared IPv4 private-range classification.

  Used by both `Tymeslot.Security.UrlValidation` (string-time SSRF check)
  and `Tymeslot.Security.DnsResolution` (request-time SSRF check) so that
  both layers agree on what counts as a private, loopback, link-local, or
  unspecified address.

  Ranges covered:
  - `0.0.0.0/8` — unspecified / "this" network (RFC 1122)
  - `10.0.0.0/8` — class A private (RFC 1918)
  - `100.64.0.0/10` — CGNAT (RFC 6598)
  - `127.0.0.0/8` — loopback (RFC 1122)
  - `169.254.0.0/16` — link-local / cloud-metadata (RFC 3927)
  - `172.16.0.0/12` — class B private (RFC 1918)
  - `192.0.0.0/24` — IETF protocol assignments (RFC 6890)
  - `192.168.0.0/16` — class C private (RFC 1918)
  - `224.0.0.0/4` — multicast (RFC 5771)
  - `240.0.0.0/4` — reserved for future use, including the `255.255.255.255`
    limited broadcast address (RFC 1112, RFC 919)
  """

  @doc """
  Returns true when the 4-tuple IPv4 address falls in a private,
  loopback, link-local, multicast, reserved, or unspecified range.
  """
  @spec private?(:inet.ip4_address()) :: boolean()
  # 0.0.0.0/8 — unspecified / "this" network
  def private?({0, _b, _c, _d}), do: true
  # 10.0.0.0/8 — class A private
  def private?({10, _b, _c, _d}), do: true
  # 100.64.0.0/10 — CGNAT (100.64.0.0–100.127.255.255)
  def private?({100, b, _c, _d}) when b >= 64 and b <= 127, do: true
  # 127.0.0.0/8 — loopback
  def private?({127, _b, _c, _d}), do: true
  # 169.254.0.0/16 — link-local / cloud-metadata
  def private?({169, 254, _c, _d}), do: true
  # 172.16.0.0/12 — class B private
  def private?({172, b, _c, _d}) when b >= 16 and b <= 31, do: true
  # 192.0.0.0/24 — IETF protocol assignments
  def private?({192, 0, 0, _d}), do: true
  # 192.168.0.0/16 — class C private
  def private?({192, 168, _c, _d}), do: true
  # 224.0.0.0/4 — multicast (224.0.0.0–239.255.255.255)
  def private?({a, _b, _c, _d}) when a >= 224 and a <= 239, do: true
  # 240.0.0.0/4 — reserved for future use, including 255.255.255.255
  def private?({a, _b, _c, _d}) when a >= 240, do: true
  def private?(_other), do: false
end
