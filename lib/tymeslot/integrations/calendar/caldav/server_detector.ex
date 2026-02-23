defmodule Tymeslot.Integrations.Calendar.CalDAV.ServerDetector do
  @moduledoc """
  Detects and provides configuration for different CalDAV server implementations.

  This module identifies the type of CalDAV server based on URLs, response headers,
  and server capabilities, then provides appropriate configuration for each server type.

  ## Supported Server Types

  - **Radicale**: Detected via hostname "radicale" or port 5232 (exact match)
  - **Nextcloud**: Detected via hostname "nextcloud" or paths `/remote.php/dav`, `/remote.php/webdav`
  - **ownCloud**: Detected via hostname "owncloud" or legacy path `/remote.php/caldav`
  - **Baikal**: Detected via hostname "baikal" or paths `/dav.php` (modern 0.4.x+), `/cal.php` (legacy 0.3.x)
    - Returns `:baikal` for modern installations with `/dav.php`
    - Returns `:baikal_legacy` for older installations with `/cal.php`
  - **SabreDAV**: Detected via hostname "sabre" or path `/server.php`
  - **Zimbra**: Detected via hostname "zimbra" or paths `/dav/`, `/principals/users/`, `/home/` (legacy)
  - **Generic**: Fallback for unrecognized CalDAV servers
  """

  @type server_type ::
          :radicale
          | :nextcloud
          | :owncloud
          | :baikal
          | :baikal_legacy
          | :sabredav
          | :zimbra
          | :generic

  @type server_profile :: %{
          type: server_type(),
          discovery_path: String.t(),
          calendar_path_pattern: String.t(),
          event_path_pattern: String.t(),
          supports_oauth: boolean(),
          supports_calendar_color: boolean(),
          supports_calendar_order: boolean(),
          requires_calendar_suffix: boolean()
        }

  @doc """
  Detects the server type from a base URL.

  Uses a two-phase detection strategy:
  1. Hostname-based detection (most reliable and specific)
  2. Path-based detection with explicit patterns (fallback)

  Note: Path-based detection checks are order-dependent. More specific patterns
  (e.g., `/dav.php`) must be checked before general patterns (e.g., `/dav/`)
  to avoid false positives.

  ## Examples

      iex> ServerDetector.detect_from_url("https://radicale.example.com:5232")
      :radicale

      iex> ServerDetector.detect_from_url("https://cloud.example.com/remote.php/dav")
      :nextcloud

      iex> ServerDetector.detect_from_url("https://cal.example.com/cal.php")
      :baikal_legacy
  """
  @spec detect_from_url(String.t()) :: server_type()
  def detect_from_url(url) when is_binary(url) do
    url_lower = String.downcase(url)

    # Phase 1: Hostname-based detection (most reliable)
    # Hostname matches are explicit and unambiguous
    case detect_by_hostname(url_lower) do
      nil ->
        # Phase 2: Path-based detection with explicit exclusions
        detect_by_path(url, url_lower) || :generic

      server_type ->
        server_type
    end
  end

  @doc """
  Detects server type based on hostname patterns.

  Hostname detection is the most reliable method as hostnames are
  typically unique to each server type.
  """
  @spec detect_by_hostname(String.t()) :: server_type() | nil
  def detect_by_hostname(url_lower) when is_binary(url_lower) do
    cond do
      String.contains?(url_lower, "radicale") -> :radicale
      String.contains?(url_lower, "nextcloud") -> :nextcloud
      String.contains?(url_lower, "owncloud") -> :owncloud
      String.contains?(url_lower, "baikal") -> :baikal
      String.contains?(url_lower, "sabre") -> :sabredav
      String.contains?(url_lower, "zimbra") -> :zimbra
      true -> nil
    end
  end

  @doc """
  Detects server type based on URL path patterns with explicit exclusions.

  IMPORTANT: Check order matters! More specific patterns (e.g., `/dav.php`, `/remote.php/dav`)
  must be checked before more general patterns (e.g., `/dav/`) to prevent false positives.

  Each path pattern includes exclusions to avoid conflicts between similar patterns.
  """
  @spec detect_by_path(String.t(), String.t()) :: server_type() | nil
  def detect_by_path(url, url_lower) when is_binary(url) and is_binary(url_lower) do
    cond do
      # Radicale: port 5232 is highly specific (exact match only)
      detect_port_5232(url) ->
        :radicale

      # PHP-based servers with specific path patterns
      php_server = detect_php_based_servers(url_lower) ->
        php_server

      # Zimbra-specific patterns
      zimbra_pattern = detect_zimbra_patterns(url_lower) ->
        zimbra_pattern

      true ->
        nil
    end
  end

  # Helper to detect exact port 5232 (not substrings like :15232)
  defp detect_port_5232(url) do
    case URI.parse(url) do
      %URI{port: 5232} -> true
      _other -> false
    end
  end

  # Detects PHP-based CalDAV servers (Nextcloud, ownCloud, Baikal, SabreDAV)
  defp detect_php_based_servers(url_lower) do
    cond do
      # Nextcloud: /remote.php/webdav (legacy, NC-specific)
      String.contains?(url_lower, "/remote.php/webdav") ->
        :nextcloud

      # ownCloud: /remote.php/caldav (legacy, OC-specific)
      String.contains?(url_lower, "/remote.php/caldav") ->
        :owncloud

      # Nextcloud/ownCloud: /remote.php/dav (modern, shared)
      # Default to Nextcloud as it's more common
      String.contains?(url_lower, "/remote.php/dav") ->
        :nextcloud

      # Baikal: /dav.php (modern Baikal 0.4.x+)
      String.contains?(url_lower, "/dav.php") ->
        :baikal

      # Baikal: /cal.php (legacy 0.3.x and earlier)
      String.contains?(url_lower, "/cal.php") ->
        :baikal_legacy

      # SabreDAV: /server.php
      String.contains?(url_lower, "/server.php") ->
        :sabredav

      true ->
        nil
    end
  end

  # Detects Zimbra-specific URL patterns
  defp detect_zimbra_patterns(url_lower) do
    cond do
      # Zimbra: /principals/users/ (highly specific to Zimbra)
      String.contains?(url_lower, "/principals/users/") ->
        :zimbra

      # Zimbra: /home/ (legacy Zimbra pattern)
      # Exclude: owncloud hostnames to avoid false positives
      String.contains?(url_lower, "/home/") and not String.contains?(url_lower, "owncloud") ->
        :zimbra

      # Zimbra: /dav/ (most common modern pattern)
      # Exclude other servers' specific patterns (checked in PHP detection)
      detect_zimbra_dav_pattern(url_lower) ->
        :zimbra

      true ->
        nil
    end
  end

  # Detects Zimbra's /dav/ pattern with proper exclusions
  defp detect_zimbra_dav_pattern(url_lower) do
    String.contains?(url_lower, "/dav/") and
      not String.contains?(url_lower, "/dav.php") and
      not String.contains?(url_lower, "/cal.php") and
      not String.contains?(url_lower, "/remote.php")
  end

  @doc """
  Detects server type from HTTP response headers.

  Some servers identify themselves in the Server or X-Powered-By headers.
  Accepts the Req.Response header map format: `%{binary() => [binary()]}`.
  """
  @spec detect_from_headers(%{optional(binary()) => [binary()]}) :: server_type() | nil
  def detect_from_headers(headers) when is_map(headers) do
    server_header = headers |> Map.get("server", []) |> List.first("") |> String.downcase()
    powered_by = headers |> Map.get("x-powered-by", []) |> List.first("") |> String.downcase()
    dav_header = headers |> Map.get("dav", []) |> List.first("") |> String.downcase()

    detect_server_from_header(server_header) ||
      detect_server_from_powered_by(powered_by) ||
      detect_server_from_dav_header(dav_header)
  end

  defp detect_server_from_header(server_header) do
    cond do
      String.contains?(server_header, "radicale") -> :radicale
      String.contains?(server_header, "nextcloud") -> :nextcloud
      String.contains?(server_header, "owncloud") -> :owncloud
      String.contains?(server_header, "baikal") -> :baikal
      String.contains?(server_header, "sabre") -> :sabredav
      String.contains?(server_header, "zimbra") -> :zimbra
      true -> nil
    end
  end

  defp detect_server_from_powered_by(powered_by) do
    cond do
      String.contains?(powered_by, "nextcloud") -> :nextcloud
      String.contains?(powered_by, "owncloud") -> :owncloud
      true -> nil
    end
  end

  defp detect_server_from_dav_header(dav_header) do
    if String.contains?(dav_header, "calendar-access") do
      :generic
    end
  end

  @doc """
  Returns the server profile for a given server type.

  The profile contains server-specific configuration and capabilities.
  """
  @spec get_server_profile(server_type()) :: server_profile()
  def get_server_profile(:radicale) do
    %{
      type: :radicale,
      discovery_path: "/{username}/",
      calendar_path_pattern: "/{username}/{calendar}/",
      event_path_pattern: "/{username}/{calendar}/{uid}.ics",
      supports_oauth: false,
      supports_calendar_color: true,
      supports_calendar_order: false,
      # Radicale calendars often end with .ics
      requires_calendar_suffix: true
    }
  end

  def get_server_profile(:nextcloud) do
    %{
      type: :nextcloud,
      discovery_path: "/remote.php/dav/calendars/{username}/",
      calendar_path_pattern: "/remote.php/dav/calendars/{username}/{calendar}/",
      event_path_pattern: "/remote.php/dav/calendars/{username}/{calendar}/{uid}.ics",
      supports_oauth: true,
      supports_calendar_color: true,
      supports_calendar_order: true,
      requires_calendar_suffix: false
    }
  end

  def get_server_profile(:owncloud) do
    %{
      type: :owncloud,
      discovery_path: "/remote.php/dav/calendars/{username}/",
      calendar_path_pattern: "/remote.php/dav/calendars/{username}/{calendar}/",
      event_path_pattern: "/remote.php/dav/calendars/{username}/{calendar}/{uid}.ics",
      supports_oauth: true,
      supports_calendar_color: true,
      supports_calendar_order: true,
      requires_calendar_suffix: false
    }
  end

  def get_server_profile(:baikal) do
    %{
      type: :baikal,
      discovery_path: "/dav.php/calendars/{username}/",
      calendar_path_pattern: "/dav.php/calendars/{username}/{calendar}/",
      event_path_pattern: "/dav.php/calendars/{username}/{calendar}/{uid}.ics",
      supports_oauth: false,
      supports_calendar_color: true,
      supports_calendar_order: false,
      requires_calendar_suffix: false
    }
  end

  def get_server_profile(:baikal_legacy) do
    %{
      type: :baikal_legacy,
      discovery_path: "/cal.php/calendars/{username}/",
      calendar_path_pattern: "/cal.php/calendars/{username}/{calendar}/",
      event_path_pattern: "/cal.php/calendars/{username}/{calendar}/{uid}.ics",
      supports_oauth: false,
      supports_calendar_color: true,
      supports_calendar_order: false,
      requires_calendar_suffix: false
    }
  end

  def get_server_profile(:sabredav) do
    %{
      type: :sabredav,
      discovery_path: "/calendars/{username}/",
      calendar_path_pattern: "/calendars/{username}/{calendar}/",
      event_path_pattern: "/calendars/{username}/{calendar}/{uid}.ics",
      supports_oauth: false,
      supports_calendar_color: true,
      supports_calendar_order: false,
      requires_calendar_suffix: false
    }
  end

  def get_server_profile(:zimbra) do
    %{
      type: :zimbra,
      discovery_path: "/dav/{username}/",
      calendar_path_pattern: "/dav/{username}/{calendar}/",
      event_path_pattern: "/dav/{username}/{calendar}/{uid}.ics",
      supports_oauth: false,
      supports_calendar_color: true,
      supports_calendar_order: false,
      requires_calendar_suffix: false
    }
  end

  def get_server_profile(_server_type) do
    # Generic CalDAV profile - works with full principal URLs
    # When users provide a full CalDAV URL (e.g., https://server.com/dav/user@domain.com),
    # this profile uses it as-is without adding additional path segments
    %{
      type: :generic,
      discovery_path: "/",
      calendar_path_pattern: "/{calendar}/",
      event_path_pattern: "/{calendar}/{uid}.ics",
      supports_oauth: false,
      supports_calendar_color: true,
      supports_calendar_order: false,
      requires_calendar_suffix: false
    }
  end

  @doc """
  Builds a discovery URL for the given server type and username.
  """
  @spec build_discovery_url(String.t(), String.t(), server_type()) :: String.t()
  def build_discovery_url(base_url, username, server_type) do
    base_url = String.trim_trailing(base_url, "/")
    profile = get_server_profile(server_type)

    path = String.replace(profile.discovery_path, "{username}", username)
    "#{base_url}#{path}"
  end

  @doc """
  Builds a calendar URL for the given server type.
  """
  @spec build_calendar_url(String.t(), String.t(), String.t(), server_type()) :: String.t()
  def build_calendar_url(base_url, username, calendar_name, server_type) do
    base_url = String.trim_trailing(base_url, "/")
    profile = get_server_profile(server_type)

    path =
      profile.calendar_path_pattern
      |> String.replace("{username}", username)
      |> String.replace("{calendar}", calendar_name)

    "#{base_url}#{path}"
  end

  @doc """
  Builds an event URL for the given server type.
  """
  @spec build_event_url(String.t(), String.t(), String.t(), String.t(), server_type()) ::
          String.t()
  def build_event_url(base_url, username, calendar_name, uid, server_type) do
    base_url = String.trim_trailing(base_url, "/")
    profile = get_server_profile(server_type)

    # Ensure UID has .ics extension if not present
    uid = if String.ends_with?(uid, ".ics"), do: uid, else: "#{uid}.ics"

    path =
      profile.event_path_pattern
      |> String.replace("{username}", username)
      |> String.replace("{calendar}", calendar_name)
      |> String.replace("{uid}.ics", uid)

    "#{base_url}#{path}"
  end

  @doc """
  Attempts to auto-detect server type by making a request to the server.

  This performs an OPTIONS or PROPFIND request to determine server capabilities.
  """
  @spec auto_detect(String.t(), String.t(), String.t()) ::
          {:ok, server_type()} | {:error, String.t()}
  def auto_detect(base_url, username, password) do
    # First try URL-based detection
    server_type = detect_from_url(base_url)

    if server_type != :generic do
      {:ok, server_type}
    else
      # Try to detect from server response headers
      case probe_server(base_url, username, password) do
        {:ok, headers} ->
          detected = detect_from_headers(headers) || :generic
          {:ok, detected}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Private functions

  defp probe_server(base_url, username, password) do
    url = String.trim_trailing(base_url, "/") <> "/"

    headers = [
      {"Authorization", "Basic " <> Base.encode64("#{username}:#{password}")}
    ]

    case http_client().request(:options, url, "", headers, receive_timeout: 5_000) do
      {:ok, %Req.Response{headers: response_headers}} ->
        {:ok, response_headers}

      {:error, reason} ->
        {:error, "Failed to probe server: #{inspect(reason)}"}
    end
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end
end
