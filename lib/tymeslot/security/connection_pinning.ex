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

  `pin/3` closes it by connecting to the address that was actually approved.
  The URL's host is replaced with that IP literal and `:hostname` is passed
  through to Mint, which uses it for TLS SNI, certificate verification and the
  `Host` header — so a virtual-hosted target behind a CDN still routes, and a
  certificate is still checked against the name the user typed rather than
  against an IP.

  ## When pinning does not apply

  `pin/3` returns `:unpinned` rather than guessing, in four cases:

    * **No approved addresses.** Nothing was resolved to pin to — the caller
      validated by syntax alone (non-production, or an operator opt-out), so
      there is no verdict to make binding.
    * **The host is already an IP literal.** There is no name to rebind.
    * **A proxy applies to this request.** The socket opens to the proxy, and
      the proxy resolves the destination itself; rewriting the host would only
      change what we ask the proxy for.
    * **A `Req` test plug is configured.** No socket is opened at all.

  ## The proxy decision is made here, once

  Whether a proxy applies is a question about the *original* hostname: an
  operator's `NO_PROXY` names `internal.example.com` or `*.example.com`, never
  the address behind it. Pinning rewrites the host to an IP literal, so a
  second evaluation further down would ask that question of a string no bypass
  list can match, and a request the operator excluded from the proxy would go
  through it after all.

  So the decision is taken here and travels with the request: a pinned request
  carries `bypass_proxy: true`, which is not an instruction to skip a proxy
  that applies but the recorded verdict that none does — pinning happens only
  when none does. `Tymeslot.Infrastructure.HTTPClient` honours it rather than
  re-deriving anything from the rewritten URL. An unpinned request keeps its
  original hostname, so the client's own evaluation of it is still correct.
  """

  alias Tymeslot.Infrastructure.ProxyConfig

  @type address :: :inet.ip_address()

  @doc """
  Returns `{:ok, pinned_url, request_options}` when the request can be pinned
  to one of `addresses`, or `:unpinned` when it cannot.

  The returned options are ordinary `Tymeslot.Infrastructure.HTTPClient`
  options and merge with the caller's own. `options` is the caller's own list:
  only `:bypass_proxy` is read from it, so that a request already going direct
  is pinned rather than left unpinned by a proxy it will never use.
  """
  @spec pin(String.t(), [address()], keyword()) :: {:ok, String.t(), keyword()} | :unpinned
  def pin(url, addresses, options \\ [])

  def pin(_url, [], _options), do: :unpinned

  def pin(url, [address | _rest], options) do
    uri = URI.parse(url)

    cond do
      is_nil(uri.host) or uri.host == "" -> :unpinned
      ip_literal?(uri.host) -> :unpinned
      test_plug_configured?() -> :unpinned
      proxied?(url, options) -> :unpinned
      true -> {:ok, rewrite_host(uri, address), pin_options(uri.host)}
    end
  end

  # `bypass_proxy: true` is the pin's own verdict travelling with the request:
  # this URL was checked against the proxy configuration under its real
  # hostname and no proxy applies to it. Without it the client would ask the
  # same question again of the IP literal, where a `NO_PROXY` entry naming the
  # host cannot match.
  defp pin_options(hostname) do
    [connect_options: [hostname: hostname], bypass_proxy: true]
  end

  defp proxied?(url, options) do
    not Keyword.get(options, :bypass_proxy, false) and
      ProxyConfig.get_proxy_for_url(url) != nil
  end

  @doc """
  Applies `pin/3` to a request, returning the URL to call and the options to
  call it with.

  Convenience for the two call sites that already hold the caller's option
  list: an unpinnable request comes back unchanged, so neither has to branch.

  `:connect_options` is merged one level deeper than the rest. It is a keyword
  list several callers already populate for reasons of their own — the
  Exchange client's `verify: :verify_none` for the self-signed certificates
  on-premises deployments carry, the custom video provider's connect timeout —
  and a flat merge would replace the caller's list with the pin's lone
  `:hostname`, silently reinstating certificate verification the operator
  turned off and dropping timeouts the caller budgeted for. The pin's own keys
  still win a collision: they are what makes the SSRF verdict binding.
  """
  @spec pin_request(String.t(), [address()], keyword()) :: {String.t(), keyword()}
  def pin_request(url, addresses, options) do
    case pin(url, addresses, options) do
      {:ok, pinned_url, pin_options} -> {pinned_url, merge_options(options, pin_options)}
      :unpinned -> {url, options}
    end
  end

  defp merge_options(options, pin_options) do
    Keyword.merge(options, pin_options, fn
      :connect_options, caller_connect, pin_connect -> Keyword.merge(caller_connect, pin_connect)
      _key, _caller, pinned -> pinned
    end)
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
