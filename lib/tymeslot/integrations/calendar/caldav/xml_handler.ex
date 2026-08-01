defmodule Tymeslot.Integrations.Calendar.CalDAV.XmlHandler do
  alias Tymeslot.Integrations.Calendar.CalendarEntry
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

  @typedoc "A parsed CalDAV event returned by `parse_calendar_query/1`."
  @type parsed_event :: %{
          required(:uid) => String.t(),
          required(:href) => String.t(),
          required(:etag) => String.t() | nil,
          required(:summary) => String.t() | nil,
          required(:description) => String.t() | nil,
          required(:location) => String.t() | nil,
          required(:attendees) => list(%{String.t() => String.t() | nil}),
          required(:recurrence_rule) => String.t() | nil,
          required(:recurrence_id) => String.t() | nil,
          required(:exdates) => list(),
          required(:start_time) => DateTime.t() | Date.t(),
          required(:end_time) => DateTime.t() | Date.t() | nil,
          required(:transparency) => String.t() | nil,
          required(:raw_ical) => String.t()
        }

  @doc """
  Builds a PROPFIND request for calendar discovery.
  """
  @spec build_propfind_request(keyword()) :: String.t()
  def build_propfind_request(opts \\ []) do
    properties =
      Keyword.get(opts, :properties, [
        :displayname,
        :resourcetype,
        :calendar_color,
        :current_user_privilege_set,
        :supported_calendar_component_set
      ])

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

  Returns the discovered calendars as `CalendarEntry` structs, produced at
  this discovery boundary so every downstream caller reads a single
  canonical shape.
  """
  @spec parse_calendar_discovery(String.t(), keyword()) ::
          {:ok, [CalendarEntry.t()]} | {:error, String.t()}
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
          ),
        component_names:
          ~x".//*[local-name()='supported-calendar-component-set']/*[local-name()='comp']/@name"sl,
        # Require an actual `<privilege>` child, not merely the element. A
        # server that does not implement RFC 3744 still echoes the property
        # NAME back inside a 404 `<propstat>` (RFC 4918 §9.1), and these
        # xpaths are not scoped to the 200 `<propstat>` — so matching the bare
        # element would read "privileges reported, none of them write" and
        # mark every calendar on such a server read-only.
        has_privilege_set:
          transform_by(
            ~x".//*[local-name()='current-user-privilege-set']/*[local-name()='privilege']",
            &(&1 != nil)
          ),
        # RFC 3744 §3.1 lets a server report the `DAV:all` aggregate, the
        # `DAV:write` aggregate, or only the leaves that `DAV:write`
        # aggregates. Any of them means the calendar is writable; matching
        # `write` alone marks a fully writable calendar read-only.
        has_write_privilege:
          transform_by(
            ~x".//*[local-name()='current-user-privilege-set']/*[local-name()='privilege']/*[local-name()='write' or local-name()='all' or local-name()='write-content' or local-name()='bind']",
            &(&1 != nil)
          )
      )
      |> Enum.filter(&include_calendar?/1)
      |> Enum.map(fn cal ->
        %CalendarEntry{
          id: cal.href,
          name: determine_calendar_name(cal),
          path: cal.href,
          color: cal.calendar_color,
          selected: Keyword.get(opts, :selected_default, false),
          read_only: read_only?(cal)
        }
      end)

    {:ok, calendars}
  rescue
    e ->
      Logger.error("XML parsing error", error: inspect(e))
      {:error, "Failed to parse calendar discovery response"}
  end

  @doc """
  Parses a calendar-query response containing events.
  """
  @spec parse_calendar_query(String.t()) :: {:ok, list(parsed_event())} | {:error, String.t()}
  def parse_calendar_query(xml_body) do
    doc = parse_with_security(xml_body)

    # Use namespace-agnostic XPath throughout — CalDAV servers use many different
    # namespace prefixes (D:, d:, no prefix, C:, cal:, etc.). local-name() matching
    # is the only portable approach across all server implementations.
    events =
      doc
      |> xpath(
        ~x"//*[local-name()='response']"l,
        href: ~x"./*[local-name()='href']/text()"s,
        etag: ~x".//*[local-name()='getetag']/text()"s,
        calendar_data: ~x".//*[local-name()='calendar-data']/text()"s
      )
      |> Enum.map(fn event ->
        case parse_ical_data(event.calendar_data) do
          {:ok, event_data} ->
            Map.merge(event_data, %{
              href: event.href,
              etag: clean_etag(event.etag),
              # Preserve the raw VCALENDAR body so it can be stored alongside
              # the parsed fields and re-parsed in place after a parser fix.
              raw_ical: event.calendar_data
            })

          {:error, _reason} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, events}
  rescue
    e ->
      Logger.error("XML parsing error", error: inspect(e))
      {:error, "Failed to parse calendar query response"}
  end

  @doc """
  Parses the `current-user-principal` href from a PROPFIND response.

  Used for RFC 4791 CalDAV principal discovery: the href points to the
  principal resource from which `calendar-home-set` can be retrieved.
  """
  @spec parse_current_user_principal(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_current_user_principal(xml_body) do
    doc = parse_with_security(xml_body)

    href =
      xpath(
        doc,
        ~x"//*[local-name()='current-user-principal']/*[local-name()='href']/text()"s
      )

    if is_binary(href) and href != "" do
      {:ok, href}
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("XML parsing error in current-user-principal", error: inspect(e))
      {:error, "Failed to parse current-user-principal response"}
  end

  @doc """
  Parses the `calendar-home-set` href from a PROPFIND response.

  Used for RFC 4791 CalDAV discovery: the href is the root URL under which
  the user's calendars are listed.
  """
  @spec parse_calendar_home_set(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_calendar_home_set(xml_body) do
    doc = parse_with_security(xml_body)

    href =
      xpath(
        doc,
        ~x"//*[local-name()='calendar-home-set']/*[local-name()='href']/text()"s
      )

    if is_binary(href) and href != "" do
      {:ok, href}
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("XML parsing error in calendar-home-set", error: inspect(e))
      {:error, "Failed to parse calendar-home-set response"}
  end

  @doc """
  Parses server capabilities from a OPTIONS or PROPFIND response.
  """
  @spec parse_server_capabilities(String.t()) ::
          {:ok,
           %{
             required(:calendar_access) => boolean(),
             required(:calendar_schedule) => boolean(),
             required(:calendar_auto_schedule) => boolean(),
             required(:supported_reports) => list(atom())
           }}
          | {:error, String.t()}
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
      Logger.error("XML parsing error", error: inspect(e))
      {:error, "Failed to parse server capabilities"}
  end

  # Private helper functions

  defp parse_with_security(xml_string) do
    # Validate XML size to prevent memory exhaustion
    # 10MB limit
    if byte_size(xml_string) > 10_000_000 do
      raise "XML document too large"
    end

    # Parse with namespace awareness and XXE prevention options.
    # xmerl (SweetXml's backend) signals fatal parse errors via Erlang :exit, not
    # Elixir exceptions. Catch and re-raise as a RuntimeError so the rescue clauses
    # in each public parser function can handle malformed XML uniformly.
    try do
      SweetXml.parse(xml_string, namespace_conformant: true, dtd: :none)
    catch
      :exit, reason -> raise "XML parse failed: #{inspect(reason)}"
    end
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

  defp build_prop_element(:current_user_privilege_set), do: "<d:current-user-privilege-set/>"

  defp build_prop_element(:supported_calendar_component_set),
    do: "<c:supported-calendar-component-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>"

  # CTag lives in the calendarserver.org namespace, not DAV:. WebDAV property
  # identity is (namespace URI, local name), so a `<d:getctag/>` request never
  # matches on the server and Tier 2 CTag sync silently never fires.
  defp build_prop_element(:getctag),
    do: "<cs:getctag xmlns:cs=\"http://calendarserver.org/ns/\"/>"

  # The property is `DAV:sync-token` (hyphen); an underscore produces a
  # nonexistent property name the server can never match.
  defp build_prop_element(:sync_token), do: "<d:sync-token/>"

  # No further fallback: a new atom reaching here would silently emit a
  # `<d:...>` element that may not exist in the DAV: namespace at all (as
  # happened with :getctag and :sync_token above). Raising surfaces the
  # missing clause immediately instead of producing a request that silently
  # never matches on the server.
  defp build_prop_element(other),
    do: raise(ArgumentError, "unknown CalDAV property atom: #{inspect(other)}")

  # Keep only calendar collections that support VEVENT. When the server omits
  # supported-calendar-component-set, accept the calendar by default — RFC 4791
  # treats VEVENT support as implied. Collections that explicitly declare
  # components without VEVENT are filtered out (e.g. mailbox.org's task-only
  # "Aufgaben" collection).
  defp include_calendar?(%{is_calendar: true, component_names: []}), do: true

  defp include_calendar?(%{is_calendar: true, component_names: names, href: href}) do
    if Enum.any?(names, &(String.upcase(&1) == "VEVENT")) do
      true
    else
      Logger.debug("CalDAV calendar excluded: no VEVENT in supported-calendar-component-set",
        href: href,
        component_names: names
      )

      false
    end
  end

  defp include_calendar?(_other), do: false

  # Only mark a calendar read-only when the server explicitly returned a
  # privilege set that omitted write access. Servers that don't advertise
  # privileges at all (most do not) are treated as writable.
  defp read_only?(%{has_privilege_set: true, has_write_privilege: false}), do: true
  defp read_only?(_other), do: false

  defp determine_calendar_name(%{displayname: displayname, href: _calendar_href})
       when displayname != "" do
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
    |> DateTime.shift_zone!("Etc/UTC")
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
      {:ok, [_first | _rest] = events} ->
        # Return the first event (single iCal string should contain one event)
        {:ok, List.first(events)}

      {:ok, []} ->
        {:error, "No events found in iCal data"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_ical_data(_invalid_data), do: {:error, "Invalid iCal data"}
end
