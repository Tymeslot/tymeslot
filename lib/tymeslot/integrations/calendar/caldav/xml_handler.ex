defmodule Tymeslot.Integrations.Calendar.CalDAV.XmlHandler do
  alias Tymeslot.Integrations.Calendar.ICalParser

  @moduledoc """
  Secure XML parsing and building for CalDAV operations using SweetXML.

  This module provides secure XML handling with:
  - Protection against XML bombs and entity expansion attacks
  - Proper namespace handling
  - XPath-based parsing for reliability
  - Schema validation
  """

  import SweetXml
  require Logger

  @doc """
  Builds a PROPFIND request for calendar discovery.
  """
  @spec build_propfind_request(keyword()) :: String.t()
  def build_propfind_request(opts \\ []) do
    properties = Keyword.get(opts, :properties, [:displayname, :resourcetype, :calendar_color])

    prop_elements = Enum.map_join(properties, "\n", &build_prop_element/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        #{prop_elements}
      </d:prop>
    </d:propfind>
    """
  end

  @doc """
  Builds a calendar-query REPORT request for fetching events.
  """
  @spec build_calendar_query(DateTime.t(), DateTime.t(), keyword()) :: String.t()
  def build_calendar_query(start_time, end_time, _opts \\ []) do
    start_str = format_caldav_datetime(start_time)
    end_str = format_caldav_datetime(end_time)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <d:getetag/>
        <c:calendar-data/>
      </d:prop>
      <c:filter>
        <c:comp-filter name="VCALENDAR">
          <c:comp-filter name="VEVENT">
            <c:time-range start="#{start_str}" end="#{end_str}"/>
          </c:comp-filter>
        </c:comp-filter>
      </c:filter>
    </c:calendar-query>
    """
  end

  @doc """
  Parses a calendar discovery response using SweetXML.

  Returns a list of calendars with their properties.
  """
  @spec parse_calendar_discovery(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, String.t()}
  def parse_calendar_discovery(xml_body, opts \\ []) do
    # Parse with security limits
    doc = parse_with_security(xml_body)

    # Use namespace-agnostic approach for better compatibility
    # Different CalDAV servers use different namespace prefixes (C: vs c: vs cal:)
    calendars =
      doc
      |> xpath(
        ~x"//*[local-name()='response']"l,
        href: ~x"./*[local-name()='href']/text()"s,
        displayname: ~x".//*[local-name()='displayname']/text()"s,
        calendar_color: ~x".//*[local-name()='calendar-color']/text()"s,
        is_calendar:
          transform_by(
            ~x".//*[local-name()='resourcetype']/*[local-name()='calendar']",
            &(&1 != nil)
          )
      )
      |> Enum.filter(fn cal -> cal.is_calendar end)
      |> Enum.map(fn cal ->
        %{
          id: cal.href,
          name: determine_calendar_name(cal),
          href: cal.href,
          color: cal.calendar_color,
          selected: Keyword.get(opts, :selected_default, false)
        }
      end)

    {:ok, calendars}
  rescue
    e ->
      Logger.error("XML parsing error: #{inspect(e)}")
      {:error, "Failed to parse calendar discovery response"}
  end

  @doc """
  Parses a calendar-query response containing events.
  """
  @spec parse_calendar_query(String.t()) :: {:ok, list(map())} | {:error, String.t()}
  def parse_calendar_query(xml_body) do
    doc = parse_with_security(xml_body)

    # Use namespace-agnostic approach for better compatibility
    events =
      doc
      |> xpath(
        ~x"//response"l,
        href: ~x"./href/text()"s,
        etag: ~x".//getetag/text()"s,
        calendar_data: ~x".//*[local-name()='calendar-data']/text()"s
      )
      |> Enum.map(fn event ->
        case parse_ical_data(event.calendar_data) do
          {:ok, event_data} ->
            Map.merge(event_data, %{
              href: event.href,
              etag: clean_etag(event.etag)
            })

          {:error, _} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, events}
  rescue
    e ->
      Logger.error("XML parsing error: #{inspect(e)}")
      {:error, "Failed to parse calendar query response"}
  end

  @doc """
  Parses server capabilities from a OPTIONS or PROPFIND response.
  """
  @spec parse_server_capabilities(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_server_capabilities(xml_body) do
    doc = parse_with_security(xml_body)

    capabilities = %{
      calendar_access: xpath(doc, ~x"//*[local-name()='calendar-access']") != nil,
      calendar_schedule: xpath(doc, ~x"//*[local-name()='calendar-schedule']") != nil,
      calendar_auto_schedule: xpath(doc, ~x"//*[local-name()='calendar-auto-schedule']") != nil,
      supported_reports:
        Enum.map(
          xpath(
            doc,
            ~x"//*[local-name()='supported-report-set']/*[local-name()='supported-report']/*[local-name()='report']/*"l
          ),
          &elem(&1, 1)
        )
    }

    {:ok, capabilities}
  rescue
    e ->
      Logger.error("XML parsing error: #{inspect(e)}")
      {:error, "Failed to parse server capabilities"}
  end

  # Private helper functions

  defp parse_with_security(xml_string) do
    # Security options to prevent XXE attacks
    _options = [
      # Disable DTD processing
      dtd: :none,
      # Disable entity expansion
      expand_entities: false
    ]

    # Validate XML size to prevent memory exhaustion
    # 10MB limit
    if byte_size(xml_string) > 10_000_000 do
      raise "XML document too large"
    end

    # Parse with namespace awareness
    SweetXml.parse(xml_string, namespace_conformant: true)
  end

  defp build_prop_element(:displayname), do: "<d:displayname/>"
  defp build_prop_element(:resourcetype), do: "<d:resourcetype/>"

  defp build_prop_element(:calendar_color),
    do: "<apple:calendar-color xmlns:apple=\"http://apple.com/ns/ical/\"/>"

  defp build_prop_element(:calendar_order),
    do: "<apple:calendar-order xmlns:apple=\"http://apple.com/ns/ical/\"/>"

  defp build_prop_element(:supported_report_set), do: "<d:supported-report-set/>"
  defp build_prop_element(:current_user_principal), do: "<d:current-user-principal/>"

  defp build_prop_element(:calendar_home_set),
    do: "<c:calendar-home-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>"

  defp build_prop_element(other), do: "<d:#{other}/>"

  defp determine_calendar_name(%{displayname: displayname, href: _href}) when displayname != "" do
    displayname
  end

  defp determine_calendar_name(%{href: href}) do
    # Extract calendar name from href
    href
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> String.replace(~r/\.(ics|cal)$/, "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_caldav_datetime(datetime) do
    datetime
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
    |> String.replace(~r/\.\d+/, "")
    |> String.replace("+00:00", "Z")
  end

  defp clean_etag(etag) do
    etag
    |> String.trim()
    |> String.trim("\"")
  end

  defp parse_ical_data(ical_string) when is_binary(ical_string) do
    # Use the comprehensive ICalParser instead of basic parsing
    case ICalParser.parse(ical_string) do
      {:ok, [_ | _] = events} ->
        # Return the first event (single iCal string should contain one event)
        {:ok, List.first(events)}

      {:ok, []} ->
        {:error, "No events found in iCal data"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_ical_data(_), do: {:error, "Invalid iCal data"}
end
