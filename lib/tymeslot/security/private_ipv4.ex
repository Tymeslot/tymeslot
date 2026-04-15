defmodule Tymeslot.Security.PrivateIPv4 do
  @moduledoc """
  Shared IPv4 private-range classification.

  Used by both `Tymeslot.Security.UrlValidation` (string-time SSRF check)
  and `Tymeslot.Security.DnsResolution` (request-time SSRF check) so that
  both layers agree on what counts as a private, loopback, link-local, or
  unspecified address.
  """

  @doc """
  Returns true when the 4-tuple IPv4 address falls in a private,
  loopback, link-local, or unspecified range.
  """
  @spec private?(:inet.ip4_address()) :: boolean()
  def private?({127, _b, _c, _d}), do: true
  def private?({10, _b, _c, _d}), do: true
  def private?({172, b, _c, _d}) when b >= 16 and b <= 31, do: true
  def private?({192, 168, _c, _d}), do: true
  def private?({169, 254, _c, _d}), do: true
  def private?({0, 0, 0, 0}), do: true
  def private?(_other), do: false
end
