defmodule Tymeslot.Integrations.Video.Providers.LinkRoom do
  @moduledoc """
  Shared core for the video providers that are addressed purely by URL:
  the custom link, kMeet and Jitsi.

  All three do the same three things (build a meeting URL, validate it, and
  hand it out), so the URL assembly, the length and scheme checks, the room-id
  derivation and the SSRF-guarded reachability probe live here rather than in
  three near-identical copies. The probe in particular carries the redirect
  budget, the overall deadline, the per-hop private-address classification and
  the `ALLOW_PRIVATE_IPS_FOR_VIDEO` opt-out; centralising it is what guarantees
  a new provider cannot quietly omit any of them.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.RedirectLocation
  alias Tymeslot.Integrations.Video.TemplateConfig
  alias Tymeslot.Security.SsrfBlockedError
  alias Tymeslot.Security.SsrfGuard

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
  @spec slug(String.t() | integer() | atom() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def slug(meeting_id)
      when is_binary(meeting_id) or is_integer(meeting_id) or is_atom(meeting_id) do
    case to_string(meeting_id) do
      "" -> {:error, "meeting_id is required but was empty"}
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
  Whether the value is an http or https URL with a non-empty host.
  """
  @spec http_url?(any()) :: boolean()
  def http_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  def http_url?(_url), do: false

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
         "dashboard_integrations",
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
  Reduces a URL to its scheme and host for logging, dropping the room path.
  """
  @spec mask_url(String.t()) :: String.t()
  def mask_url(url) when is_binary(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}/..."
  end

  @doc """
  Checks that a URL answers, following redirects and classifying every hop
  through `Tymeslot.Security.SsrfGuard`.

  Returns the final 2xx status, or the status of a 3xx whose target cannot be
  followed, since that is still a host that answered. Every failure carries a
  user-facing message.
  """
  @spec probe(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def probe(url), do: check_reachable(url, @max_redirects, probe_deadline())

  defp hash_meeting_id(meeting_id) do
    :crypto.hash(:sha256, to_string(meeting_id))
    |> Base.encode16(case: :lower)
    |> String.slice(0, TemplateConfig.hash_length())
  end

  defp probe_deadline, do: System.monotonic_time(:millisecond) + @overall_budget_ms

  # Built per call rather than as a module attribute: the opt-out is read from
  # application config at runtime, and an attribute would freeze it at compile
  # time. `budget_ms` shrinks the per-request timeout to whatever remains of
  # the overall probe deadline, capped at the original 3s.
  defp probe_opts(budget_ms) do
    per_request_timeout = min(3_000, budget_ms)

    [
      receive_timeout: per_request_timeout,
      connect_options: [timeout: per_request_timeout],
      ssrf_protect: true,
      ssrf_allow_private: SsrfGuard.allow_private_for_video?()
    ]
  end

  defp check_reachable(_url, hops_left, _deadline) when hops_left < 0 do
    {:error, dgettext("dashboard_integrations", "URL redirects too many times")}
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
    {:error,
     dgettext("dashboard_integrations", "URL responded with HTTP %{status}", status: status)}
  end

  defp blocked_url_message,
    do: dgettext("dashboard_integrations", "URL resolves to a private or loopback address")

  defp url_timeout_message,
    do: dgettext("dashboard_integrations", "Connection timeout while reaching the URL")

  defp unreachable_url_message(reason),
    do: dgettext("dashboard_integrations", "Failed to reach URL: %{reason}", reason: reason)
end
