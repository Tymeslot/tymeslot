defmodule Tymeslot.Security.DnsResolution do
  @moduledoc """
  DNS-resolving SSRF protection for server-side HTTP requests.

  Resolves a URL's hostname via `:inet.getaddr/2` and checks whether the
  resolved IP falls within private or local network ranges. Use this at
  request time (not changeset time) to avoid TOCTOU gaps.

  For string-based (non-resolving) private IP checks at changeset time,
  use `Tymeslot.Security.UrlValidation` with `block_private_ips: true`.
  """

  @default_error "URL resolves to a private or local network address"

  @spec check_private_ip(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_private_ip(url, opts \\ []) do
    error_message = Keyword.get(opts, :error_message, @default_error)

    case URI.parse(url).host do
      nil -> {:error, error_message}
      "" -> {:error, error_message}
      host -> resolve_and_check(to_charlist(host), error_message)
    end
  end

  defp resolve_and_check(host_charlist, error_message) do
    ipv4_result = ipv4_private?(host_charlist)
    ipv6_result = ipv6_private?(host_charlist)

    cond do
      ipv4_result or ipv6_result ->
        {:error, error_message}

      not resolvable?(host_charlist) ->
        {:error, error_message}

      true ->
        :ok
    end
  end

  defp resolvable?(host_charlist) do
    match?({:ok, _addr}, :inet.getaddr(host_charlist, :inet)) or
      match?({:ok, _addr}, :inet.getaddr(host_charlist, :inet6))
  end

  defp ipv4_private?(host_charlist) do
    case :inet.getaddr(host_charlist, :inet) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {10, _b, _c, _d}} -> true
      {:ok, {172, b, _c, _d}} when b >= 16 and b <= 31 -> true
      {:ok, {192, 168, _c, _d}} -> true
      {:ok, {169, 254, _c, _d}} -> true
      {:ok, {0, 0, 0, 0}} -> true
      _other -> false
    end
  end

  defp ipv6_private?(host_charlist) do
    case :inet.getaddr(host_charlist, :inet6) do
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0xFE80, _s2, _s3, _s4, _s5, _s6, _s7, _s8}} -> true
      {:ok, {0xFC00, _s2, _s3, _s4, _s5, _s6, _s7, _s8}} -> true
      {:ok, {0xFD00, _s2, _s3, _s4, _s5, _s6, _s7, _s8}} -> true
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, hi, lo}} -> ipv4_mapped_private?(hi, lo)
      _other -> false
    end
  end

  defp ipv4_mapped_private?(hi, lo) do
    a = Bitwise.bsr(hi, 8)
    b = Bitwise.band(hi, 0xFF)
    _c = Bitwise.bsr(lo, 8)
    _d = Bitwise.band(lo, 0xFF)

    case {a, b} do
      {127, _b} -> true
      {10, _b} -> true
      {172, x} when x >= 16 and x <= 31 -> true
      {192, 168} -> true
      {169, 254} -> true
      {0, 0} -> true
      _other -> false
    end
  end
end
