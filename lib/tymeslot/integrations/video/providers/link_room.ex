defmodule Tymeslot.Integrations.Video.Providers.LinkRoom do
  @moduledoc """
  Shared core for the video providers addressed by a URL on a server the user
  names: the custom link, kMeet and Jitsi build their rooms here, and Nextcloud
  Talk, whose rooms its own API creates, reuses the server address checks
  (`validate_base_url/1`, `http_url?/1`).

  The link providers do the same three things (build a meeting URL, validate
  it, and hand it out), so the URL assembly, the length and scheme checks, the
  room-id derivation and the SSRF-guarded reachability probe live here rather
  than in near-identical copies. The probe in particular carries the redirect
  budget, the overall deadline, the per-hop private-address classification and
  the `ALLOW_PRIVATE_IPS_FOR_VIDEO` opt-out; centralising it is what guarantees
  a new provider cannot quietly omit any of them.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.RedirectLocation
  alias Tymeslot.Integrations.Video.Providers.SsrfOptions
  alias Tymeslot.Integrations.Video.TemplateConfig
  alias Tymeslot.Security.SsrfBlockedError

  # The host is user-supplied, so every hop is classified in its own right.
  # `ssrf_protect: true` hands the private-address decision to `SsrfGuard`,
  # which resolves every A and AAAA record, is gated to `:prod` so a local video
  # container stays reachable in development, and honours the operator's
  # ALLOW_PRIVATE_IPS_FOR_VIDEO opt-out. It also forcibly sets `redirect: false`
  # and validates only the URL it is handed, so letting the client follow
  # redirects itself would leave every hop after the first unchecked: a host
  # that resolves publicly can 302 straight to 127.0.0.1 or the cloud metadata
  # endpoint. Following them here reports status, timeout and
  # connection-refused apart. The ICS feed fetcher has the identical problem
  # and the same shape; `Tymeslot.Infrastructure.RedirectLocation` is the one
  # place both resolve a hop's target, and documents the budget convention
  # this counter follows (`hops_left < 0` refuses, so 3 means three follows).
  @max_redirects 3

  # Each request was previously bounded per-hop only (3s connect + 3s receive),
  # so the worst case grew with every added hop: up to `@max_redirects + 1`
  # hops, two requests each (HEAD then a GET fallback), was ~48s with no
  # overall bound. This caps the whole probe (HEAD, GET fallback and every
  # redirect hop together) at the original single-hop worst case, shrinking
  # each subsequent request's own timeout to whatever budget remains rather
  # than handing out a fresh 3s per hop.
  @overall_budget_ms 12_000

  @doc """
  Derives the room slug for a meeting: the first `TemplateConfig.hash_length/0`
  hex characters of the SHA256 of the meeting id.

  Hashing keeps the id out of the URL and makes query strings, fragments and
  path traversal in the id inert. A `nil` or empty id is refused, since every
  meeting would otherwise share the same room.
  """
  @spec slug(String.t() | integer() | atom() | nil) ::
          {:ok, String.t()} | {:error, :empty_meeting_id}
  def slug(meeting_id)
      when is_binary(meeting_id) or is_integer(meeting_id) or is_atom(meeting_id) do
    case to_string(meeting_id) do
      "" -> {:error, :empty_meeting_id}
      string_id -> {:ok, hash_meeting_id(string_id)}
    end
  end

  @doc """
  Appends a slug to a base URL as its last path segment, with exactly one
  separator however the base URL ends.
  """
  @spec append_slug(String.t(), String.t()) :: String.t()
  def append_slug(base_url, slug) do
    String.trim_trailing(base_url, "/") <> "/" <> slug
  end

  @doc """
  Builds a room on a fixed host: hashes the meeting id into a slug, appends
  it to `base_url`, and validates the result's length. This is the whole
  room-creation flow shared by every provider addressed purely by URL and a
  meeting id (kMeet, Jitsi); the custom provider stays off this path because
  it also has a static-URL mode and substitutes the slug into a template
  rather than always appending it.

  Refuses a missing meeting id with a plain-English message rather than the
  bare `:empty_meeting_id` atom `slug/1` returns, since this is the entry
  point callers use directly. Refuses a base URL that `validate_base_url/1`
  rejects.
  """
  @spec build_room(String.t(), String.t() | integer() | atom() | nil) ::
          {:ok, %{room_id: String.t(), meeting_url: String.t()}} | {:error, String.t()}
  def build_room(base_url, meeting_id) do
    with :ok <- validate_base_url(base_url),
         {:ok, room_id} <- slug_or_missing_id_message(meeting_id),
         meeting_url = append_slug(base_url, room_id),
         :ok <- validate_length(meeting_url) do
      {:ok, %{room_id: room_id, meeting_url: meeting_url}}
    end
  end

  defp slug_or_missing_id_message(meeting_id) do
    case slug(meeting_id) do
      {:ok, room_id} ->
        {:ok, room_id}

      {:error, :empty_meeting_id} ->
        {:error, dgettext("dashboard_video", "A meeting ID is required to create a video room")}
    end
  end

  @doc """
  Refuses a base URL that cannot safely have a room path appended.

    * Whitespace inside the address (surrounding whitespace is ignored): it
      would end up in every room link.
    * A login name or password in the address (`https://user:pass@host`): every
      room link is built from the address and sent to guests, so the
      credentials would travel with it.
    * A query string or a fragment: the room slug is appended to the path, so
      anything after it would end up in front of the slug
      (`https://m.example.com/?x=1/<slug>`), the room lands somewhere other
      than the path says, and `slug_from_url/1` no longer finds it.

  A plain sub-path (`https://example.com/jitsi`) is fine.
  """
  @spec validate_base_url(String.t()) :: :ok | {:error, String.t()}
  def validate_base_url(base_url) do
    trimmed = String.trim(base_url)

    cond do
      String.match?(trimmed, ~r/\s/u) ->
        {:error,
         dgettext(
           "dashboard_video",
           "The server URL cannot contain spaces. Enter only the address of the server."
         )}

      URI.parse(trimmed).userinfo != nil ->
        {:error,
         dgettext(
           "dashboard_video",
           "The server URL cannot contain a login name or password. Enter only the address of the server."
         )}

      match?(%URI{query: nil, fragment: nil}, URI.parse(trimmed)) ->
        :ok

      true ->
        {:error,
         dgettext(
           "dashboard_video",
           "The server URL cannot contain a query string (?) or a fragment (#). Enter only the address of the server."
         )}
    end
  end

  @doc """
  Whether the value is an http or https URL with a non-empty host.
  """
  @spec http_url?(any()) :: boolean()
  def http_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  def http_url?(_url), do: false

  @doc """
  Whether the value is an http or https URL naming a room: one with a
  non-empty path segment for `slug_from_url/1` to return.
  """
  @spec room_url?(any()) :: boolean()
  def room_url?(url), do: http_url?(url) and slug_from_url(url) != nil

  @doc """
  Refuses a URL longer than the database column holding it allows.
  """
  @spec validate_length(String.t()) :: :ok | {:error, String.t()}
  def validate_length(url) do
    url_length = String.length(url)
    max_length = TemplateConfig.max_url_length()

    if url_length <= max_length do
      :ok
    else
      {:error,
       dgettext(
         "dashboard_video",
         "Processed URL exceeds maximum length of %{max_length} characters (got %{url_length})",
         max_length: max_length,
         url_length: url_length
       )}
    end
  end

  @doc """
  Derives a stable 16-character room id from a meeting URL.
  """
  @spec room_id(String.t()) :: String.t()
  def room_id(url) do
    :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  @doc """
  Extracts the room id from a meeting URL built by `build_room/2`: the last
  non-empty path segment. Returns `nil` for a URL with no path (or one that
  is only slashes), since there is no segment to return; a room built by
  `build_room/2` always has one, so this only bites a hand-edited or foreign
  URL.
  """
  @spec slug_from_url(String.t()) :: String.t() | nil
  def slug_from_url(url) do
    path = url |> URI.parse() |> Map.get(:path)

    case path do
      nil -> nil
      path -> path |> String.split("/", trim: true) |> List.last()
    end
  end

  @doc """
  Reduces a URL to its scheme and host for logging, dropping the room path.

  Callers reach this on a failure path, where the URL may be whatever they
  were handed rather than a parsed one, so anything that is not a string
  masks to `"none"` instead of raising. A log line must not be able to turn
  a warning into a crash.
  """
  @spec mask_url(any()) :: String.t()
  def mask_url(url) when is_binary(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}/..."
  end

  def mask_url(_url), do: "none"

  @doc """
  Checks that a URL answers, following redirects and classifying every hop
  through `Tymeslot.Security.SsrfGuard`.

  A URL whose scheme is not http or https is refused before any request is
  made. Returns the final 2xx status, or the status of a 3xx whose target
  cannot be followed, since that is still a host that answered. Every failure,
  the scheme refusal included, carries a user-facing message.
  """
  @spec probe(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def probe(url) do
    with :ok <- assert_http_or_https(url) do
      check_reachable(url, @max_redirects, probe_deadline())
    end
  end

  @doc """
  Probes a URL and renders the result as the connection-test message every
  link-room provider shows the user: a status line on success, `probe/1`'s
  own message on failure.
  """
  @spec connection_test(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def connection_test(url) do
    with {:ok, status} <- probe(url) do
      # Shares the msgid the non-2xx branches use: the caller wraps a
      # success in "✓ Custom provider configured - …", so the status
      # line does not have to carry the verdict itself.
      {:ok, dgettext("dashboard_video", "URL responded with HTTP %{status}", status: status)}
    end
  end

  defp hash_meeting_id(meeting_id) do
    :crypto.hash(:sha256, meeting_id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, TemplateConfig.hash_length())
  end

  # Deliberately looser than `http_url?/1`: the probe checks only the scheme
  # here and leaves a hostless URL to fail in the request itself, so the user
  # sees the probe's own reason rather than a scheme error.
  defp assert_http_or_https(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] do
      :ok
    else
      {:error,
       dgettext(
         "dashboard_video",
         "Invalid URL scheme. Only http and https are supported"
       )}
    end
  end

  defp probe_deadline, do: System.monotonic_time(:millisecond) + @overall_budget_ms

  # `budget_ms` shrinks the per-request timeout to whatever remains of the
  # overall probe deadline, capped at the original 3s.
  defp probe_opts(budget_ms) do
    per_request_timeout = min(3_000, budget_ms)

    [receive_timeout: per_request_timeout, connect_options: [timeout: per_request_timeout]] ++
      SsrfOptions.request_options()
  end

  defp check_reachable(_url, hops_left, _deadline) when hops_left < 0 do
    {:error, dgettext("dashboard_video", "URL redirects too many times")}
  end

  defp check_reachable(url, hops_left, deadline) do
    with {:ok, budget_ms} <- remaining_budget(deadline) do
      case Config.http_client_module().head(url, [], probe_opts(budget_ms)) do
        {:ok, %{status: 405}} ->
          do_get(url, hops_left, deadline)

        {:ok, response} ->
          classify_probe(response, url, hops_left, deadline)

        {:error, %SsrfBlockedError{}} ->
          {:error, blocked_url_message()}

        {:error, _reason} ->
          do_get(url, hops_left, deadline)
      end
    end
  end

  defp do_get(url, hops_left, deadline) do
    with {:ok, budget_ms} <- remaining_budget(deadline) do
      case Config.http_client_module().get(url, [], probe_opts(budget_ms)) do
        {:ok, response} ->
          classify_probe(response, url, hops_left, deadline)

        {:error, %SsrfBlockedError{}} ->
          {:error, blocked_url_message()}

        {:error, exception} when is_exception(exception) ->
          case exception do
            %Mint.TransportError{reason: :timeout} ->
              {:error, url_timeout_message()}

            %Req.TransportError{reason: :timeout} ->
              {:error, url_timeout_message()}

            _network_exception ->
              {:error, unreachable_url_message(Exception.message(exception))}
          end

        {:error, reason} ->
          {:error, unreachable_url_message(inspect(reason))}
      end
    end
  end

  defp remaining_budget(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, url_timeout_message()}
    end
  end

  defp classify_probe(%{status: status} = response, url, hops_left, deadline)
       when status in 300..399 do
    case RedirectLocation.next_url(Map.get(response, :headers, %{}), url) do
      # A 3xx we cannot follow is still a host that answered, so the probe
      # reports the status rather than calling the URL unreachable.
      {:error, _unfollowable} -> {:ok, status}
      {:ok, target} -> check_reachable(target, hops_left - 1, deadline)
    end
  end

  defp classify_probe(%{status: status}, _url, _hops_left, _deadline) when status in 200..299 do
    {:ok, status}
  end

  defp classify_probe(%{status: status}, _url, _hops_left, _deadline) do
    {:error, dgettext("dashboard_video", "URL responded with HTTP %{status}", status: status)}
  end

  defp blocked_url_message,
    do: dgettext("dashboard_video", "URL resolves to a private or loopback address")

  defp url_timeout_message,
    do: dgettext("dashboard_video", "Connection timeout while reaching the URL")

  defp unreachable_url_message(reason),
    do: dgettext("dashboard_video", "Failed to reach URL: %{reason}", reason: reason)
end
