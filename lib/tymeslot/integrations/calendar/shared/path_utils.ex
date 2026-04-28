defmodule Tymeslot.Integrations.Calendar.Shared.PathUtils do
  @moduledoc """
  Shared path manipulation utilities for CalDAV-based providers.

  Provides common functions for URL and path manipulation used by both
  CalDAV and Nextcloud providers.
  """

  @doc """
  Normalizes a CalDAV URL to ensure proper formatting.

  ## Parameters
  - `url` - The URL to normalize
  - `opts` - Options for normalization
    - `:ensure_trailing_slash` - Ensures the path ends with `/` (default: true)
    - `:provider` - Provider type for specific normalization (any atom returned by
      `Tymeslot.Integrations.Calendar.ProviderConfig.caldav_based_providers/0`)

  ## Returns
  - Normalized URL string

  ## Examples
      
      iex> PathUtils.normalize_url("https://example.com/caldav")
      "https://example.com/caldav/"
      
      iex> PathUtils.normalize_url("example.com", provider: :nextcloud)
      "https://example.com/remote.php/dav/"
      
      iex> PathUtils.normalize_url("radicale.example.com:5232", provider: :radicale)
      "https://radicale.example.com:5232"
  """
  @spec normalize_url(String.t(), keyword()) :: String.t()
  def normalize_url(url, opts \\ []) do
    ensure_trailing_slash = Keyword.get(opts, :ensure_trailing_slash, true)
    provider = Keyword.get(opts, :provider, :caldav)

    url
    |> ensure_scheme()
    |> maybe_add_provider_path(provider)
    |> maybe_ensure_trailing_slash(ensure_trailing_slash)
  end

  @doc """
  Ensures a URL has a proper `http://` or `https://` scheme.

  Defensive against malformed scheme prefixes such as `https:/host` (single
  slash), `https:host`, `//host`, or a bare host. Any of these are normalised
  to `https://host` rather than being naively concatenated, which would
  otherwise produce garbage like `https://https:/host`.

  ## Parameters
  - `url` - The URL to process

  ## Returns
  - URL with a valid scheme
  """
  @spec ensure_scheme(String.t()) :: String.t()
  def ensure_scheme(url) when is_binary(url) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      trimmed
    else
      stripped =
        trimmed
        |> String.replace(~r{^\s*https?:/*}i, "")
        |> String.replace(~r{^/+}, "")

      "https://" <> stripped
    end
  end

  # CalDAV-family URLs users frequently paste from their browser: Nextcloud's
  # DAV endpoints, its index.php front controller, and any app route. Match
  # only on the URI path so hostnames like cloud.example.com are never touched.
  @caldav_browser_path_suffix ~r{/(?:remote\.php/(?:dav|webdav)|index\.php|apps)(?:/.*)?$}

  @doc """
  Canonicalises a user-supplied CalDAV/Nextcloud server URL to its base form.

  Ensures an http/https scheme, parses the URL structurally, strips known
  browser/endpoint path suffixes (`/remote.php/dav…`, `/remote.php/webdav…`,
  `/index.php…`, `/apps…`), and removes a trailing slash. Subpath installs
  such as `https://example.com/nextcloud` are preserved.

  If the input cannot be parsed into `scheme://host`, the scheme-normalised
  string is returned unchanged so downstream validators can reject it with
  a precise error.

  ## Examples

      iex> PathUtils.normalize_base_url("cloud.example.com")
      "https://cloud.example.com"

      iex> PathUtils.normalize_base_url("https://cloud.example.com/apps/calendar/dayGridMonth/2026-04-20")
      "https://cloud.example.com"

      iex> PathUtils.normalize_base_url("https://example.com/nextcloud/remote.php/dav/calendars/user/personal/")
      "https://example.com/nextcloud"
  """
  @spec normalize_base_url(String.t()) :: String.t()
  def normalize_base_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    # Preserve disallowed-scheme inputs (javascript:, file:, data:, ftp:)
    # verbatim so URLValidator can reject them with its precise error rather
    # than being silently rewritten into a benign-looking https URL.
    case URI.parse(trimmed) do
      %URI{scheme: scheme} when scheme not in [nil, "http", "https"] ->
        trimmed

      _http_or_bare ->
        normalize_http_base_url(trimmed)
    end
  end

  defp normalize_http_base_url(trimmed) do
    with_scheme = ensure_scheme(trimmed)

    case URI.parse(with_scheme) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        path =
          (parsed.path || "")
          |> String.replace(@caldav_browser_path_suffix, "")
          |> String.trim_trailing("/")

        port_suffix =
          if parsed.port && parsed.port not in [80, 443], do: ":#{parsed.port}", else: ""

        "#{scheme}://#{host}#{port_suffix}#{path}"

      _unparseable ->
        with_scheme
    end
  end

  @doc """
  Extracts the base URL from a full CalDAV URL.

  ## Parameters
  - `full_url` - The full CalDAV URL

  ## Returns
  - Base URL (scheme + host + optional port)

  ## Examples
      
      iex> PathUtils.extract_base_url("https://example.com:5232/caldav/user/calendar/")
      "https://example.com:5232"
  """
  @spec extract_base_url(String.t()) :: String.t()
  def extract_base_url(full_url) do
    uri = URI.parse(full_url)
    port_suffix = if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""
    "#{uri.scheme}://#{uri.host}#{port_suffix}"
  end

  @doc """
  Extracts calendar paths from full CalDAV URLs.

  ## Parameters
  - `urls` - List of full CalDAV URLs or a newline-separated string

  ## Returns
  - Tuple of {base_url, calendar_paths}

  ## Examples
      
      iex> PathUtils.extract_calendar_paths("https://example.com/caldav/user/cal1/\\nhttps://example.com/caldav/user/cal2/")
      {"https://example.com", ["/caldav/user/cal1/", "/caldav/user/cal2/"]}
  """
  @spec extract_calendar_paths(String.t() | list(String.t())) :: {String.t(), list(String.t())}
  def extract_calendar_paths(urls) when is_binary(urls) do
    split = String.split(urls, "\n")
    trimmed = Enum.map(split, &String.trim/1)
    non_empty = Enum.reject(trimmed, &(&1 == ""))
    extract_calendar_paths(non_empty)
  end

  def extract_calendar_paths(urls) when is_list(urls) do
    base_url =
      case urls do
        [first_url | _rest] -> extract_base_url(first_url)
        _empty -> ""
      end

    calendar_paths =
      Enum.map(urls, fn url ->
        uri = URI.parse(url)
        path = uri.path || "/"
        if String.ends_with?(path, "/"), do: path, else: path <> "/"
      end)

    {base_url, calendar_paths}
  end

  @doc """
  Builds a full CalDAV URL from base URL and calendar path.

  ## Parameters
  - `base_url` - The base URL
  - `calendar_path` - The calendar path

  ## Returns
  - Full CalDAV URL
  """
  @spec build_full_url(String.t(), String.t()) :: String.t()
  def build_full_url(base_url, calendar_path) do
    base = String.trim_trailing(base_url, "/")

    path =
      if String.starts_with?(calendar_path, "/"), do: calendar_path, else: "/" <> calendar_path

    base <> path
  end

  @doc """
  Checks if a path is a simple calendar name or a full path.

  ## Parameters
  - `path` - The path to check

  ## Returns
  - `:simple` if it's just a calendar name, `:full` if it's a full path
  """
  @spec path_type(String.t()) :: :simple | :full
  def path_type(path) do
    if String.contains?(path, "/"), do: :full, else: :simple
  end

  @doc """
  Converts a simple calendar name to a full CalDAV path.

  ## Parameters
  - `calendar_name` - Simple calendar name
  - `username` - Username for the calendar
  - `opts` - Options including :provider

  ## Returns
  - Full calendar path
  """
  @spec simple_to_full_path(String.t(), String.t(), keyword()) :: String.t()
  def simple_to_full_path(calendar_name, username, opts \\ []) do
    provider = Keyword.get(opts, :provider, :caldav)

    case provider do
      # Nextcloud: Uses /remote.php/dav/calendars/{username}/{calendar}/
      :nextcloud ->
        "/remote.php/dav/calendars/#{username}/#{calendar_name}/"

      # Radicale: Uses /{username}/{calendar-uuid}/
      :radicale ->
        "/#{username}/#{calendar_name}/"

      # Zimbra: Uses /dav/{username}/{calendar}/
      :zimbra ->
        "/dav/#{username}/#{calendar_name}/"

      # Generic CalDAV: Uses /calendars/{username}/{calendar}/
      _other ->
        "/calendars/#{username}/#{calendar_name}/"
    end
  end

  @doc """
  Extracts username from a Nextcloud calendar URL if present.

  ## Parameters
  - `url` - The URL to extract username from

  ## Returns
  - `{:ok, username}` if username found, `:error` otherwise

  ## Examples
      
      iex> PathUtils.extract_nextcloud_username("https://cloud.example.com/remote.php/dav/calendars/john/")
      {:ok, "john"}
      
      iex> PathUtils.extract_nextcloud_username("https://cloud.example.com")
      :error
  """
  @spec extract_nextcloud_username(String.t()) :: {:ok, String.t()} | :error
  def extract_nextcloud_username(url) when is_binary(url) do
    # Pattern to match Nextcloud calendar URLs
    calendar_pattern = ~r{/remote\.php/dav/calendars/([^/]+)}

    case Regex.run(calendar_pattern, url) do
      [_full_match, username] -> {:ok, username}
      _no_match -> :error
    end
  end

  def extract_nextcloud_username(_url), do: :error

  @doc """
  Checks if a URL is a Nextcloud calendar URL.

  ## Parameters
  - `url` - The URL to check

  ## Returns
  - `true` if it's a calendar URL, `false` otherwise
  """
  @spec nextcloud_calendar_url?(String.t()) :: boolean()
  def nextcloud_calendar_url?(url) when is_binary(url) do
    String.contains?(url, "/remote.php/dav/calendars/")
  end

  def nextcloud_calendar_url?(_url), do: false

  # Private helper functions

  defp maybe_add_provider_path(url, :nextcloud) do
    # Nextcloud: Add /remote.php/dav if not present
    cond do
      # URL already contains the DAV endpoint - keep as is
      String.contains?(url, "/remote.php/dav") ->
        url

      # URL contains index.php or apps - it's likely a direct Nextcloud URL, extract base
      String.contains?(url, "/index.php") or String.contains?(url, "/apps/") ->
        # Extract base URL up to the Nextcloud root
        base = extract_base_url(url)
        base <> "/remote.php/dav"

      # Clean base URL - add the DAV endpoint
      true ->
        uri = URI.parse(url)
        base = extract_base_url(url)

        # Preserve any existing path but add Nextcloud DAV endpoint
        existing_path = uri.path || ""

        if existing_path == "/" or existing_path == "" do
          base <> "/remote.php/dav"
        else
          # Keep original URL if it has a specific path
          url
        end
    end
  end

  # Radicale: No special path additions needed
  defp maybe_add_provider_path(url, :radicale), do: url

  # Generic CalDAV: No special path additions needed
  defp maybe_add_provider_path(url, _other_provider), do: url

  defp maybe_ensure_trailing_slash(url, false), do: url

  defp maybe_ensure_trailing_slash(url, true) do
    uri = URI.parse(url)

    if uri.path && !String.ends_with?(uri.path, "/") do
      url <> "/"
    else
      url
    end
  end
end
