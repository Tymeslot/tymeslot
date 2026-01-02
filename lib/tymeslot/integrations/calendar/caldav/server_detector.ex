defmodule Tymeslot.Integrations.Calendar.CalDAV.ServerDetector do
  @moduledoc """
  Detects and provides configuration for different CalDAV server implementations.

  This module identifies the type of CalDAV server based on URLs, response headers,
  and server capabilities, then provides appropriate configuration for each server type.
  """

  @type server_type :: :radicale | :nextcloud | :owncloud | :baikal | :sabredav | :generic

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

  ## Examples

      iex> ServerDetector.detect_from_url("https://radicale.example.com:5232")
      :radicale
      
      iex> ServerDetector.detect_from_url("https://cloud.example.com/remote.php/dav")
      :nextcloud
  """
  @spec detect_from_url(String.t()) :: server_type()
  def detect_from_url(url) when is_binary(url) do
    url_lower = String.downcase(url)

    detect_radicale(url, url_lower) ||
      detect_nextcloud(url, url_lower) ||
      detect_owncloud(url_lower) ||
      detect_baikal(url, url_lower) ||
      detect_sabredav(url, url_lower) ||
      :generic
  end

  defp detect_radicale(url, url_lower) do
    if String.contains?(url_lower, "radicale") or String.contains?(url, ":5232") do
      :radicale
    end
  end

  defp detect_nextcloud(url, url_lower) do
    if String.contains?(url_lower, "nextcloud") or
         String.contains?(url, "/remote.php/dav") or
         String.contains?(url, "/remote.php/webdav") do
      :nextcloud
    end
  end

  defp detect_owncloud(url_lower) do
    if String.contains?(url_lower, "owncloud") do
      :owncloud
    end
  end

  defp detect_baikal(url, url_lower) do
    if String.contains?(url_lower, "baikal") or String.contains?(url, "/cal.php") do
      :baikal
    end
  end

  defp detect_sabredav(url, url_lower) do
    if String.contains?(url_lower, "sabre") or String.contains?(url, "/server.php") do
      :sabredav
    end
  end

  @doc """
  Detects server type from HTTP response headers.

  Some servers identify themselves in the Server or X-Powered-By headers.
  """
  @spec detect_from_headers(list({String.t(), String.t()})) :: server_type() | nil
  def detect_from_headers(headers) when is_list(headers) do
    headers_map = Map.new(headers, fn {k, v} -> {String.downcase(k), String.downcase(v)} end)

    server_header = Map.get(headers_map, "server", "")
    powered_by = Map.get(headers_map, "x-powered-by", "")
    dav_header = Map.get(headers_map, "dav", "")

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

  def get_server_profile(_) do
    # Generic CalDAV profile
    %{
      type: :generic,
      discovery_path: "/calendars/{username}/",
      calendar_path_pattern: "/calendars/{username}/{calendar}/",
      event_path_pattern: "/calendars/{username}/{calendar}/{uid}.ics",
      supports_oauth: false,
      supports_calendar_color: false,
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

    request = Finch.build(:options, url, headers)

    case Finch.request(request, Tymeslot.Finch, receive_timeout: 5_000) do
      {:ok, %Finch.Response{headers: response_headers}} ->
        {:ok, response_headers}

      {:error, reason} ->
        {:error, "Failed to probe server: #{inspect(reason)}"}
    end
  end
end
