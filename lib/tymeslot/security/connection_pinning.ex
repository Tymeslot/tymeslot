defmodule Tymeslot.Security.ConnectionPinning do
  @moduledoc """
  Turns an SSRF-approved address into the request options that make the
  approval binding.

  Every SSRF verdict this application makes is about a *hostname*, resolved
  once by `Tymeslot.Security.DnsResolution`. Handing the URL string on to
  Req/Finch then resolves that same hostname a second time, independently, when
  the socket opens. Between the two answers a record with a short TTL can move
  from a public address to `127.0.0.1` or `169.254.169.254`: the classic
  DNS-rebinding bypass, which needs no redirect and which re-checking closer to
  the connect cannot close, because every resolve-then-connect design has the
  window.

  `pin/2` closes it by connecting to the address that was actually approved.
  The URL's host is replaced with that IP literal and `:hostname` is passed
  through to Mint, which uses it for TLS SNI, certificate verification and the
  `Host` header — so a virtual-hosted target behind a CDN still routes, and a
  certificate is still checked against the name the user typed rather than
  against an IP.

  ## When pinning does not apply

  `pin/2` returns `:unpinned` rather than guessing, in four cases:

    * **No approved addresses.** Nothing was resolved to pin to — the caller
      validated by syntax alone (non-production, or an operator opt-out), so
      there is no verdict to make binding.
    * **The host is already an IP literal.** There is no name to rebind.
    * **A proxy applies to this URL.** The socket opens to the proxy, and the
      proxy resolves the destination itself; rewriting the host would only
      change what we ask the proxy for.
    * **A `Req` test plug is configured.** No socket is opened at all.
  """

  alias Tymeslot.Infrastructure.ProxyConfig

  @type address :: :inet.ip_address()

  @doc """
  Returns `{:ok, pinned_url, request_options}` when the request can be pinned
  to one of `addresses`, or `:unpinned` when it cannot.

  The returned options are ordinary `Tymeslot.Infrastructure.HTTPClient`
  options and merge with the caller's own.
  """
  @spec pin(String.t(), [address()]) :: {:ok, String.t(), keyword()} | :unpinned
  def pin(_url, []), do: :unpinned

  def pin(url, [address | _rest]) do
    uri = URI.parse(url)

    cond do
      is_nil(uri.host) or uri.host == "" -> :unpinned
      ip_literal?(uri.host) -> :unpinned
      test_plug_configured?() -> :unpinned
      not is_nil(ProxyConfig.get_proxy_for_url(url)) -> :unpinned
      true -> {:ok, rewrite_host(uri, address), [connect_options: [hostname: uri.host]]}
    end
  end

  @doc """
  Applies `pin/2` to a request, returning the URL to call and the options to
  call it with.

  Convenience for the two call sites that already hold the caller's option
  list: an unpinnable request comes back unchanged, so neither has to branch.
  """
  @spec pin_request(String.t(), [address()], keyword()) :: {String.t(), keyword()}
  def pin_request(url, addresses, options) do
    case pin(url, addresses) do
      {:ok, pinned_url, pin_options} -> {pinned_url, Keyword.merge(options, pin_options)}
      :unpinned -> {url, options}
    end
  end

  @doc """
  Whether `host` is already an IP address rather than a name.
  """
  @spec ip_literal?(String.t()) :: boolean()
  def ip_literal?(host) do
    unbracketed = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(to_charlist(unbracketed)) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  # `URI.to_string/1` brackets a host containing colons itself, so an IPv6
  # address needs no bracketing here — adding it produces a doubly-bracketed
  # authority that nothing downstream parses.
  defp rewrite_host(uri, address) do
    URI.to_string(%{uri | host: address |> :inet.ntoa() |> to_string()})
  end

  defp test_plug_configured? do
    not is_nil(Application.get_env(:tymeslot, :req_test_plug))
  end
end
