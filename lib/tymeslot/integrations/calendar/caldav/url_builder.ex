defmodule Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder do
  @moduledoc """
  URL construction helpers for CalDAV operations.

  Centralises the logic for building discovery URLs, calendar URLs, and event
  URLs from a base URL and server-root-relative paths returned by CalDAV servers.
  """

  @doc """
  Builds the initial discovery URL for a CalDAV client.

  If `base_url` already looks like a full CalDAV principal URL (path depth ≥ 2),
  it is used as-is. A CalDAV *service root* is excluded from that test, however
  deep it sits: it addresses the DAV mount rather than a calendar collection, so
  the provider-specific path is still appended to it.
  """
  @spec build_discovery_url(map()) :: String.t()
  def build_discovery_url(client) do
    base_url = String.trim_trailing(client.base_url, "/")

    if full_caldav_url?(base_url) do
      "#{base_url}/"
    else
      case client.provider do
        :radicale ->
          "#{base_url}/#{client.username}/"

        :nextcloud ->
          if String.contains?(base_url, "/calendars/#{client.username}") do
            "#{base_url}/"
          else
            "#{base_url}/calendars/#{client.username}/"
          end

        :zimbra ->
          "#{base_url}/dav/#{client.username}/"

        :mailbox_org ->
          "#{base_url}/caldav/"

        _other ->
          "#{base_url}/calendars/#{client.username}/"
      end
    end
  end

  @doc """
  Builds a full URL from `base_url` and `calendar_path`.

  `calendar_path` is normalised first: an *absolute* href (e.g. iCloud returns
  `calendar-home-set` as `https://p110-caldav.icloud.com/…/calendars/`, on a
  per-user partition host) is reduced to its path so the request stays pinned to
  the already SSRF-validated `base_url` host rather than following a
  server-supplied redirect to an arbitrary, unvalidated host.

  When the resulting path starts with `/` it is treated as server-root-relative
  (as CalDAV PROPFIND hrefs always are). In that case only the origin
  (`scheme://host[:port]`) of `base_url` is used, preventing path doubling when
  `base_url` itself already contains a CalDAV principal path.

  When it does not start with `/` it is appended directly to `base_url` (used
  for relative paths during initial discovery construction).
  """
  @spec build_calendar_url(String.t(), String.t()) :: String.t()
  def build_calendar_url(base_url, calendar_path), do: resolve_href(base_url, calendar_path)

  @doc """
  Resolves any server-supplied href against `base_url`.

  Every href a CalDAV server hands back — a calendar collection from PROPFIND,
  an event resource from a REPORT or the `Location` of a create — resolves the
  same way, so they share one function. A root-relative href resolves against
  the *origin* of `base_url` and not against the whole of it: `base_url` may
  itself carry a CalDAV path (`https://host/remote.php/dav`, which is what a
  Nextcloud subpath install and a pasted DAV URL both look like), and
  concatenating the two doubles that path into a URL the server answers with
  404. Resolving an event href against the whole `base_url` is what
  `Events.resolve_event_url/4` used to do, and because a CalDAV DELETE counts
  404 as success, the resulting delete reported success without deleting
  anything.
  """
  @spec resolve_href(String.t(), String.t()) :: String.t()
  def resolve_href(base_url, href) do
    path = origin_relative_path(href)

    if String.starts_with?(path, "/") do
      %URI{scheme: scheme, host: host, port: port} = URI.parse(base_url)
      "#{scheme}://#{host}#{port_str(scheme, port)}#{path}"
    else
      "#{String.trim_trailing(base_url, "/")}/#{path}"
    end
  end

  @doc """
  Builds the full URL for a specific event resource.
  """
  @spec build_event_url(String.t(), String.t(), String.t()) :: String.t()
  def build_event_url(base_url, calendar_path, uid) do
    "#{build_calendar_url(base_url, calendar_path)}#{uid}.ics"
  end

  @doc """
  Resolves the URL of a single event resource.

  Prefers the server-supplied `href` (stored as `provider_event_id`) when the
  event has been synced: it is the event's real location, and is the only way
  to address an event living on a calendar other than `calendar_path`. Falls
  back to the resource Tymeslot writes for `uid` under `calendar_path` for
  events that have not been synced back yet.

  The href is resolved through `build_calendar_url/2`, so a server-root-relative
  href resolves against the base *origin* rather than being appended to a
  `base_url` that already carries the same DAV path, and an absolute href stays
  pinned to the validated base host.
  """
  @spec resolve_event_url(String.t(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :unaddressable}
  def resolve_event_url(base_url, _calendar_path, _uid, href)
      when is_binary(href) and href != "",
      do: {:ok, build_calendar_url(base_url, href)}

  def resolve_event_url(base_url, calendar_path, uid, _href)
      when is_binary(calendar_path) and is_binary(uid) and uid != "",
      do: {:ok, build_event_url(base_url, calendar_path, uid)}

  def resolve_event_url(_base_url, _calendar_path, _uid, _href), do: {:error, :unaddressable}

  # CalDAV hrefs are normally server-root-relative paths, but some providers —
  # notably iCloud — return an *absolute* URL on a different host (a per-user
  # partition like `p110-caldav.icloud.com`). Reduce such hrefs to their path
  # (and query) so the request resolves against the already-validated base host
  # instead of following an unvalidated, server-supplied redirect. Non-absolute
  # hrefs (root-relative paths, relative paths) pass through unchanged.
  defp origin_relative_path(href) do
    case URI.parse(href) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        path = uri.path || "/"
        if uri.query, do: "#{path}?#{uri.query}", else: path

      _not_absolute ->
        href
    end
  end

  # Detects if a URL already looks like a full CalDAV principal URL
  # (e.g., /dav/user@example.com or /remote.php/dav/calendars/user).
  defp full_caldav_url?(base_url) do
    case URI.parse(base_url).path do
      nil ->
        false

      "/" ->
        false

      path ->
        segments = String.split(path, "/", trim: true)
        length(segments) >= 2 and not caldav_service_root?(segments)
    end
  end

  # `Shared.PathUtils.normalize_url/2` turns a bare Nextcloud host into
  # `.../remote.php/dav` before this module ever sees it (see
  # `Nextcloud.Provider.new/1`). That path has depth 2, so it used to satisfy
  # `full_caldav_url?/1` and get treated as an already-specific calendar
  # collection — skipping the `/calendars/{username}/` this module would
  # otherwise append. The resulting request queried the CalDAV *service
  # root*, whose PROPFIND response lists top-level collections
  # (files/, addressbooks/, calendars/, ...) that never carry a
  # `<cal:calendar/>` resourcetype, so discovery silently returned zero
  # calendars for every Nextcloud account — no error, no log, just an empty
  # list indistinguishable from "this user really has no calendars".
  #
  # Matched as a suffix, not an exact path: Nextcloud is frequently installed in
  # a subdirectory, where the same normalisation yields `/nextcloud/remote.php/dav`.
  # An exact two-segment match would leave those installations on the original
  # broken path.
  defp caldav_service_root?(segments), do: Enum.take(segments, -2) == ["remote.php", "dav"]

  # Only include port when it differs from the scheme default.
  # URI.parse/1 always fills in the default port (443 for https, 80 for http),
  # so we must suppress it to avoid producing https://host:443/... URLs.
  defp port_str("https", 443), do: ""
  defp port_str("http", 80), do: ""
  defp port_str(_scheme, port) when is_integer(port), do: ":#{port}"
  defp port_str(_scheme, _port), do: ""
end
