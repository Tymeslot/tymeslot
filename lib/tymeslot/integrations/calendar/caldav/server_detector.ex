defmodule Tymeslot.Integrations.Calendar.CalDAV.ServerDetector do
  @moduledoc """
  Detects which CalDAV server implementation a URL belongs to.

  Classification is by URL alone: the hostname and the well-known path each
  implementation serves its DAV endpoint under. `CalDAV.Provider.new/1` uses the
  result to pick the path-construction rules for that server, falling back to
  generic CalDAV handling for anything unrecognised.

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
          | :mailbox_org
          | :apple
          | :generic

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
      String.contains?(url_lower, "mailbox.org") -> :mailbox_org
      String.contains?(url_lower, "icloud.com") -> :apple
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
end
