defmodule Tymeslot.Integrations.Calendar.Ics.Feed do
  @moduledoc """
  Fetches and parses a published iCalendar feed.

  The network half of the `ics_url` provider, kept separate from
  `Tymeslot.Integrations.Calendar.Ics.Provider` because it is the only part
  that touches the outside world: the provider's own read path serves the
  local event cache, and only the sync worker and the connection test come
  through here.

  Feed URLs are supplied by the user and point at hosts we know nothing
  about, so every request is SSRF-guarded, capped in size, and limited to two
  redirect hops — each hop revalidated in turn, since `HTTPClient` disables
  Req's automatic redirect following precisely so a public host cannot bounce
  us onto an internal address.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Security.SsrfBlockedError

  # Published calendars are whole-account exports with no date-range
  # parameter, so the only bound on what a feed returns is this one. 10 MB is
  # roughly a decade of a busy diary; anything larger is a misconfiguration or
  # a deliberate attempt to exhaust memory, and both deserve the same answer.
  @max_feed_bytes 10 * 1024 * 1024

  @max_redirects 2

  @redirect_statuses [301, 302, 303, 307, 308]

  @typedoc """
  Why a feed could not be read. `:unauthorised` is the one the sync worker
  treats as terminal: a feed URL that starts refusing us is revoked or
  rotated, and no amount of retrying brings it back.
  """
  @type error ::
          :unauthorised
          | :not_found
          | :too_large
          | :invalid_ics
          | :too_many_redirects
          | :missing_url
          | {:http_status, pos_integer()}
          | {:transport, term()}
          | {:blocked, term()}

  @doc """
  Fetches `url` and parses it as iCalendar, returning raw parser events.

  The events are the same shape `ICalParser` produces for CalDAV payloads, so
  `Tymeslot.Integrations.Calendar.ICalNormaliser` turns them into
  `CalendarEvent` structs without a feed-specific branch.
  """
  @spec fetch_events(String.t(), keyword()) :: {:ok, [map()]} | {:error, error()}
  def fetch_events(url, opts \\ []) when is_binary(url) do
    with {:ok, body} <- fetch_body(normalise_url(url), opts, @max_redirects) do
      parse(body)
    end
  end

  @doc """
  Rewrites the `webcal://` scheme every calendar vendor hands out in its
  "subscribe" UI to `https://`, regardless of casing (`WebCal://`,
  `WEBCAL://`, ...) or surrounding whitespace. Anything else is returned
  trimmed but otherwise untouched.
  """
  @spec normalise_url(String.t()) :: String.t()
  def normalise_url(url) do
    trimmed = String.trim(url)

    case String.split(trimmed, "://", parts: 2) do
      [scheme, rest] ->
        if String.downcase(scheme) == "webcal", do: "https://" <> rest, else: trimmed

      _no_scheme ->
        trimmed
    end
  end

  @doc "The largest feed body this module will accept, in bytes."
  @spec max_feed_bytes() :: pos_integer()
  def max_feed_bytes, do: @max_feed_bytes

  @doc """
  User-facing copy for a fetch failure.

  Lives here, next to the error type it describes, so the connect form and
  the sync worker say the same thing about the same failure instead of
  drifting into two vocabularies for one problem.
  """
  @spec error_message(error()) :: String.t()
  def error_message(:unauthorised),
    do: "The calendar feed rejected the link. It may have been revoked or reset."

  def error_message(:not_found),
    do: "The calendar feed URL returned 404. Check that the link is complete and still published."

  def error_message(:invalid_ics),
    do: "That URL did not return a calendar feed. Make sure it points at an .ics file."

  def error_message(:too_large), do: "That calendar feed is too large to process."

  def error_message(:too_many_redirects), do: "The calendar feed redirected too many times."

  def error_message(:missing_url), do: "Enter the calendar feed URL."

  def error_message({:blocked, _reason}),
    do: "That URL points at a blocked address and cannot be reached."

  def error_message({:http_status, status}),
    do: "The calendar feed returned HTTP #{status}."

  def error_message(_reason),
    do: "Could not reach the calendar feed. Check the URL and try again."

  defp fetch_body(_url, _opts, redirects_left) when redirects_left < 0 do
    {:error, :too_many_redirects}
  end

  defp fetch_body(url, opts, redirects_left) do
    request_opts =
      opts
      |> Keyword.take([:ssrf_allow_private, :receive_timeout])
      |> Keyword.put(:ssrf_protect, true)

    case Config.http_client_module().get(
           url,
           [{"accept", "text/calendar, text/plain;q=0.9, */*;q=0.8"}],
           request_opts
         ) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        handle_response(status, body, headers, url, opts, redirects_left)

      {:error, %SsrfBlockedError{reason: reason}} ->
        {:error, {:blocked, reason}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp handle_response(status, body, _headers, _url, _opts, _redirects_left)
       when status in 200..299 do
    within_size_limit(body)
  end

  defp handle_response(status, _body, headers, url, opts, redirects_left)
       when status in @redirect_statuses do
    case redirect_target(headers, url) do
      {:ok, target} -> fetch_body(target, opts, redirects_left - 1)
      :error -> {:error, {:http_status, status}}
    end
  end

  defp handle_response(status, _body, _headers, _url, _opts, _redirects_left)
       when status in [401, 403],
       do: {:error, :unauthorised}

  defp handle_response(404, _body, _headers, _url, _opts, _redirects_left),
    do: {:error, :not_found}

  defp handle_response(status, _body, _headers, _url, _opts, _redirects_left),
    do: {:error, {:http_status, status}}

  # Req normalises response headers to lower-cased string keys holding a list
  # of values.
  defp redirect_target(headers, current_url) do
    location =
      case headers["location"] do
        [value | _rest] -> value
        value when is_binary(value) -> value
        _other -> nil
      end

    case location && URI.merge(URI.parse(current_url), location) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, URI.to_string(uri)}

      _other ->
        :error
    end
  end

  # Servers are free to omit content-length, so the cap is enforced on what
  # actually arrived rather than on what was advertised.
  defp within_size_limit(body) when is_binary(body) do
    if byte_size(body) > @max_feed_bytes do
      {:error, :too_large}
    else
      {:ok, body}
    end
  end

  defp within_size_limit(_body), do: {:error, :invalid_ics}

  defp parse(body) do
    case ICalParser.parse(body) do
      {:ok, events} ->
        {:ok, events}

      {:error, reason} ->
        Logger.warning("Subscribed calendar feed did not parse as iCalendar",
          reason: inspect(reason)
        )

        {:error, :invalid_ics}
    end
  end
end
