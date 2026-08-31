defmodule Tymeslot.Infrastructure.RedirectLocation do
  @moduledoc """
  Works out where a single HTTP redirect hop points.

  `Tymeslot.Infrastructure.HTTPClient` force-sets `redirect: false` on every
  SSRF-guarded request, and `Tymeslot.Webhooks.HttpDelivery` does the same on
  its own requests, precisely so that no hop after the first can be followed
  unvalidated: a host that resolves publicly must not be able to bounce the
  request onto loopback, a private range, or the cloud-metadata endpoint. The
  cost of that decision is that any caller needing to follow a 3xx must issue a
  fresh, separately validated request per hop.

  Three subsystems do exactly that — webhook delivery, the ICS feed fetcher and
  the custom video-provider reachability probe — and all three need the same
  answer to the same question: given the response headers and the URL that
  produced them, what absolute URL does this hop name? That question, and only
  that question, lives here.

  ## What deliberately stays with the callers

  The hop *loops* are not shared, because what surrounds the question differs
  in kind rather than in configuration. Webhook delivery switches method by
  status class (RFC 9110 §15.4) and strips credential headers when a hop
  crosses origins; the video probe runs HEAD with a GET fallback under a single
  overall deadline; the feed fetcher classifies 401/403/404 as terminal and
  caps the body size. Folding those into one function would need a callback per
  difference, which buys less than it costs. Validation placement differs too:
  the feed and video probes hand each hop to `HTTPClient` with
  `ssrf_protect: true`, so `Tymeslot.Security.SsrfGuard` validates it inside
  the client, while webhook delivery calls `Tymeslot.Webhooks.SsrfValidator`
  itself before each hop because it enforces a stricter, HTTPS-only policy.

  ## Hop accounting

  Callers hold a budget of *redirects to follow*, guard their recursive entry
  point on `hops_left < 0`, and recurse with `hops_left - 1` when they follow
  one. A budget of `n` therefore issues up to `n + 1` requests and follows `n`
  redirects. Guarding on `hops_left == 0` instead follows `n - 1`, which is the
  off-by-one webhook delivery carried until this module documented the
  convention; keep new callers on the `< 0` form.
  """

  @typedoc "Response headers in either shape a client hands back."
  @type headers :: map() | list()

  @typedoc """
  Why this hop cannot be followed. `:missing_location` is a 3xx with no
  `Location` header at all; `:unsupported_target` is a `Location` that resolves
  to something other than an absolute `http`/`https` URL (`mailto:`, `ftp:`, a
  scheme-only string). Callers keep their own vocabulary for these — a feed
  reports the raw status, the video probe reports the status as reachable, and
  webhook delivery distinguishes a missing header from a blocked target.
  """
  @type error :: :missing_location | :unsupported_target

  # A redirect we are willing to chase must be plain HTTP. Anything else is
  # refused here rather than being handed to an SSRF check that would reject it
  # for a less specific reason.
  @followable_schemes ["http", "https"]

  @doc """
  Resolves the `Location` header of a 3xx response against `current_url`.

  Accepts headers as a map of lower-cased keys (what Req hands back, values
  either a binary or a list of binaries) or as a list of `{key, value}` pairs,
  in which case the key match is case-insensitive.

  The header value is resolved against `current_url` per RFC 3986 §5.2, so an
  absolute URL, a network-path reference (`//host/path`), an absolute path
  (`/path`) and a relative path all produce an absolute URL.

      iex> alias Tymeslot.Infrastructure.RedirectLocation
      iex> RedirectLocation.next_url(%{"location" => ["/next"]}, "https://a.test/here")
      {:ok, "https://a.test/next"}
      iex> RedirectLocation.next_url(%{"location" => "//b.test/x"}, "https://a.test/here")
      {:ok, "https://b.test/x"}
      iex> RedirectLocation.next_url(%{}, "https://a.test/here")
      {:error, :missing_location}
      iex> RedirectLocation.next_url(%{"location" => "mailto:x@b.test"}, "https://a.test/x")
      {:error, :unsupported_target}
  """
  @spec next_url(headers(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def next_url(headers, current_url) do
    case location_value(headers) do
      nil -> {:error, :missing_location}
      location -> resolve(location, current_url)
    end
  end

  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  defp resolve(location, current_url) do
    case URI.merge(URI.parse(current_url), location) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in @followable_schemes and is_binary(host) and host != "" ->
        {:ok, URI.to_string(uri)}

      _unfollowable ->
        {:error, :unsupported_target}
    end
  end

  @spec location_value(headers()) :: String.t() | nil
  defp location_value(headers) when is_map(headers) do
    case Map.get(headers, "location") do
      [value | _rest] when is_binary(value) -> value
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp location_value(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) or is_atom(key) ->
        if String.downcase(to_string(key)) == "location", do: to_string(value)

      _other ->
        nil
    end)
  end

  defp location_value(_headers), do: nil
end
