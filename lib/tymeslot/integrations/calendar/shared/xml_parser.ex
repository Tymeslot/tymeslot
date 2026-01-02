defmodule Tymeslot.Integrations.Calendar.Shared.XmlParser do
  @moduledoc """
  Shared XML parsing utilities for CalDAV-based providers.

  Provides common XML parsing functions used by both CalDAV and Nextcloud providers
  to avoid code duplication and ensure consistent parsing behavior.
  """

  @doc """
  Parses calendar discovery response XML and extracts calendar information.

  ## Parameters
  - `xml_body` - The XML response body from a PROPFIND request
  - `opts` - Options for parsing (e.g., `:include_id` to add an id field)

  ## Returns
  - `{:ok, calendars}` - List of calendar maps with path, name, and optional fields
  - `{:error, reason}` - Error if parsing fails

  ## Examples
      
      iex> xml = "<d:href>/calendars/user/personal/</d:href><d:displayname>Personal</d:displayname>"
      iex> XmlParser.parse_calendar_discovery_response(xml)
      {:ok, [%{path: "/calendars/user/personal/", name: "Personal", type: "calendar"}]}
  """
  @spec parse_calendar_discovery_response(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, String.t()}
  def parse_calendar_discovery_response(xml_body, opts \\ []) do
    include_id = Keyword.get(opts, :include_id, false)
    include_selected = Keyword.get(opts, :include_selected, false)

    # Get calendar responses specifically (those containing calendar resourcetype)
    calendar_responses = extract_calendar_responses(xml_body)

    calendars =
      Enum.map(calendar_responses, fn {href, name} ->
        # Clean up the display name and use path extraction as fallback
        display_name = String.trim(name || "")

        calendar_name =
          if display_name == "" do
            extract_calendar_name_from_path(href)
          else
            display_name
          end

        base_calendar = %{
          path: href,
          name: calendar_name,
          type: "calendar"
        }

        base_calendar
        |> maybe_add_id(href, include_id)
        |> maybe_add_selected(include_selected)
      end)

    {:ok, calendars}
  rescue
    _ -> {:error, "Failed to parse calendar discovery response"}
  end

  @doc """
  Extracts a calendar name from its path.

  ## Parameters
  - `path` - The calendar path (e.g., "/remote.php/dav/calendars/username/personal/")

  ## Returns
  - The extracted calendar name or "calendar" as fallback

  ## Examples
      
      iex> XmlParser.extract_calendar_name_from_path("/calendars/user/work/")
      "work"
      
      iex> XmlParser.extract_calendar_name_from_path("/remote.php/dav/calendars/admin/personal/")
      "personal"
  """
  @spec extract_calendar_name_from_path(String.t()) :: String.t()
  def extract_calendar_name_from_path(path) do
    # Handle different CalDAV path structures
    segments =
      path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    case segments do
      # Nextcloud format: ["remote.php", "dav", "calendars", "username", "calendar_name"]
      [_, "dav", "calendars", _username, calendar_name | _] ->
        calendar_name

      # Standard CalDAV format: ["calendars", "username", "calendar_name"]
      ["calendars", _username, calendar_name | _] ->
        calendar_name

      # Generic fallback - take the last non-empty segment
      [_ | _] = segments ->
        List.last(segments)

      _ ->
        "calendar"
    end
  end

  @doc """
  Builds a PROPFIND XML request for calendar discovery.

  ## Returns
  - XML string for PROPFIND request
  """
  @spec build_propfind_request() :: String.t()
  def build_propfind_request do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <d:resourcetype />
        <d:displayname />
        <cs:getctag />
        <c:supported-calendar-component-set />
      </d:prop>
    </d:propfind>
    """
  end

  @doc """
  Parses a calendar home set from a PROPFIND response.

  ## Parameters
  - `xml_body` - The XML response body

  ## Returns
  - The calendar home URL or nil if not found
  """
  @spec parse_calendar_home_set(String.t()) :: String.t() | nil
  def parse_calendar_home_set(xml_body) do
    case Regex.run(~r/<cal:calendar-home-set><d:href>([^<]+)<\/d:href>/, xml_body) do
      [_, home_set] -> home_set
      _ -> nil
    end
  end

  @doc """
  Determines if a response indicates a calendar collection.

  ## Parameters
  - `xml_body` - The XML response body

  ## Returns
  - `true` if the response indicates a calendar collection, `false` otherwise
  """
  @spec calendar_collection?(String.t()) :: boolean()
  def calendar_collection?(xml_body) do
    String.contains?(xml_body, "<cal:calendar") ||
      String.contains?(xml_body, "calendar-collection")
  end

  # Private helper functions

  # Extract calendar responses by identifying responses that contain calendar resourcetype
  defp extract_calendar_responses(xml_body) do
    # Split into individual response elements, handle both namespaced and non-namespaced
    responses =
      if String.contains?(xml_body, "<d:response>") do
        String.split(xml_body, "<d:response>")
        # Remove the first empty element
        |> Enum.drop(1)
        |> Enum.map(&("<d:response>" <> &1))
      else
        String.split(xml_body, "<response>")
        # Remove the first empty element
        |> Enum.drop(1)
        |> Enum.map(&("<response>" <> &1))
      end

    # Filter for responses containing calendar resourcetype
    calendar_responses =
      Enum.filter(responses, fn response ->
        String.contains?(response, "<C:calendar") ||
          String.contains?(response, "<c:calendar") ||
          String.contains?(response, "<cal:calendar") ||
          String.contains?(response, "<d:calendar") ||
          String.contains?(response, "calendar-collection")
      end)

    # Extract href and displayname from each calendar response
    mapped =
      Enum.map(calendar_responses, fn response ->
        href = extract_href_from_response(response)
        name = extract_displayname_from_response(response)
        {href, name}
      end)

    Enum.filter(mapped, fn {href, _name} -> href != nil end)
  end

  defp extract_href_from_response(response) do
    # Try both namespaced and non-namespaced patterns
    case Regex.run(~r/<d:href>([^<]+)<\/d:href>/, response) do
      [_, href] ->
        href

      _ ->
        case Regex.run(~r/<href>([^<]+)<\/href>/, response) do
          [_, href] -> href
          _ -> nil
        end
    end
  end

  defp extract_displayname_from_response(response) do
    # Try both namespaced and non-namespaced patterns
    case Regex.run(~r/<d:displayname>([^<]*)<\/d:displayname>/, response) do
      [_, name] ->
        name

      _ ->
        case Regex.run(~r/<displayname>([^<]*)<\/displayname>/, response) do
          [_, name] -> name
          _ -> ""
        end
    end
  end

  defp maybe_add_id(calendar, href, true), do: Map.put(calendar, :id, href)
  defp maybe_add_id(calendar, _href, false), do: calendar

  defp maybe_add_selected(calendar, true), do: Map.put(calendar, :selected, false)
  defp maybe_add_selected(calendar, false), do: calendar
end
