defmodule Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder do
  @moduledoc """
  URL construction helpers for CalDAV operations.

  Centralises the logic for building discovery URLs, calendar URLs, and event
  URLs from a base URL and server-root-relative paths returned by CalDAV servers.
  """

  @doc """
  Builds the initial discovery URL for a CalDAV client.

  If `base_url` already looks like a full CalDAV principal URL (path depth ≥ 2),
  it is used as-is. Otherwise a provider-specific path is appended.
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
  def build_calendar_url(base_url, calendar_path) do
    path = origin_relative_path(calendar_path)

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
      nil -> false
      "/" -> false
      path -> length(String.split(path, "/", trim: true)) >= 2
    end
  end

  # Only include port when it differs from the scheme default.
  # URI.parse/1 always fills in the default port (443 for https, 80 for http),
  # so we must suppress it to avoid producing https://host:443/... URLs.
  defp port_str("https", 443), do: ""
  defp port_str("http", 80), do: ""
  defp port_str(_scheme, port) when is_integer(port), do: ":#{port}"
  defp port_str(_scheme, _port), do: ""
end
