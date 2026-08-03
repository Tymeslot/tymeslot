defmodule Tymeslot.Integrations.Calendar.ICalParser do
  @moduledoc """
  Robust iCal/vCalendar parser that handles various edge cases and formats.
  Replaces the problematic 'magical' library with a custom implementation.
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.VTimezone
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils.Duration
  alias Tymeslot.Utils.DateTimeUtils.ICal

  @doc """
  Parses iCal content and returns a list of events.

  Returns {:ok, events} or {:error, reason}
  """
  @spec parse(binary()) :: {:ok, list(map())} | {:error, String.t()}
  def parse(ical_content) when is_binary(ical_content) do
    start_time = System.monotonic_time()
    size = byte_size(ical_content)

    # Parsing iCal content

    # Normalize line endings and trim
    content = normalize_content(ical_content)

    result =
      if valid_ical_format?(content) do
        events = extract_events(content)
        # Successfully parsed events
        {:ok, events}
      else
        Logger.error("Invalid iCal format")
        {:error, "Invalid iCal format"}
      end

    # Track parsing performance
    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    event_count =
      case result do
        {:ok, events} -> length(events)
        {:error, _reason} -> 0
      end

    Metrics.track_parsing_performance(:ical, size, duration_ms, event_count)

    result
  rescue
    error ->
      Logger.error("Failed to parse iCal content", error: inspect(error))
      {:error, "Parse error: #{inspect(error)}"}
  end

  @doc """
  Parses CalDAV multistatus XML response containing multiple calendar entries.
  """
  @spec parse_multistatus(binary()) :: {:ok, list(map())}
  def parse_multistatus(xml_body) when is_binary(xml_body) do
    trimmed_body = String.trim(xml_body)
    if trimmed_body == "", do: {:ok, []}, else: parse_calendars_from_multistatus(trimmed_body)
  end

  defp parse_calendars_from_multistatus(trimmed_body) do
    calendars = extract_calendars_from_xml(trimmed_body)

    events = Enum.flat_map(calendars, &parse_calendar_data/1)

    {:ok, events}
  end

  defp parse_calendar_data(calendar_data) do
    case parse(calendar_data) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  # Private functions

  defp normalize_content(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim()
  end

  defp valid_ical_format?(content) do
    String.contains?(content, "BEGIN:VCALENDAR") &&
      String.contains?(content, "END:VCALENDAR")
  end

  defp extract_events(content) do
    # Build the embedded VTIMEZONE map once per VCALENDAR. It carries only the
    # custom, non-IANA zones bundled in the payload (RFC 5545 §3.6.5) and is
    # consulted by `parse_datetime_property/2` solely for TZIDs the configured
    # time zone database can't resolve — IANA zones never touch it.
    vtimezones = VTimezone.parse(content)

    content
    |> extract_vevent_blocks()
    |> Enum.map(&parse_event_block(&1, vtimezones))
    |> Enum.filter(&(&1 != nil))
  end

  defp extract_vevent_blocks(content) do
    content
    |> String.split("BEGIN:VEVENT")
    |> Enum.drop(1)
    |> Enum.map(fn block ->
      case String.split(block, "END:VEVENT", parts: 2) do
        [event_content | _rest] -> "BEGIN:VEVENT\n" <> event_content <> "\nEND:VEVENT"
        [] -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp parse_event_block(event_block, vtimezones) do
    lines = unfold_lines(event_block)

    # Extract properties
    uid = extract_property(lines, "UID")
    summary = extract_property(lines, "SUMMARY")
    description = extract_property(lines, "DESCRIPTION")
    location = extract_property(lines, "LOCATION")
    organizer = extract_organizer(lines)
    attendees = extract_attendees(lines)
    recurrence_rule = extract_property(lines, "RRULE")
    recurrence_id = extract_recurrence_id(lines)
    exdates = extract_exdates(lines, vtimezones)

    # Parse dates with timezone support
    dtstart = extract_datetime_property(lines, "DTSTART")
    dtend = extract_datetime_property(lines, "DTEND")

    start_time = parse_datetime_property(dtstart, vtimezones)

    end_time =
      parse_datetime_property(dtend, vtimezones) ||
        calculate_end_time(start_time, extract_property(lines, "DURATION"))

    if uid && start_time do
      %{
        uid: uid,
        summary: summary,
        description: description,
        location: location,
        organizer: organizer,
        attendees: attendees,
        recurrence_rule: recurrence_rule,
        recurrence_id: recurrence_id,
        recurrence_id_range: extract_recurrence_id_range(lines),
        exdates: exdates,
        start_time: start_time,
        end_time: end_time,
        # The DTSTART TZID as written on the wire, already sanitised to an IANA
        # name. `start_time`/`end_time` above are converted to UTC, which throws
        # the zone away — recurring events need it back to expand occurrences in
        # local wall-clock time across a DST transition (see
        # `Tymeslot.Integrations.Calendar.ICalNormaliser.expand_event/3`). `nil` for UTC, floating, and
        # DATE-valued events, none of which have a zone to restore.
        timezone: dtstart_timezone(dtstart),
        transparency: normalize_transp(extract_property(lines, "TRANSP")),
        status: extract_property(lines, "STATUS"),
        class: extract_property(lines, "CLASS"),
        colour:
          extract_property(lines, "COLOR") || extract_property(lines, "X-APPLE-CALENDAR-COLOR")
      }
    else
      Logger.debug("Skipping event with missing required fields",
        uid: uid,
        summary: summary,
        has_start: !is_nil(start_time)
      )

      nil
    end
  end

  defp dtstart_timezone(%{timezone: timezone}) when is_binary(timezone), do: timezone
  defp dtstart_timezone(_dtstart), do: nil

  defp unfold_lines(content) do
    content
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      # Continuation line (starts with space or tab)
      if String.match?(line, ~r/^[\s\t]/) && acc != [] do
        [last | rest] = acc
        # RFC 5545 §3.1: unfold by removing the leading whitespace, no extra space
        [last <> String.trim_leading(line) | rest]
      else
        # New line
        [line | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp extract_attendees(lines) do
    lines
    |> Enum.filter(&String.starts_with?(&1, "ATTENDEE"))
    |> Enum.map(&parse_attendee_line/1)
    |> Enum.reject(fn a -> is_nil(a["email"]) end)
  end

  # RFC 5545 §3.8.4.3 — a VEVENT carries at most one ORGANIZER. Returns the
  # same `"email"`/`"name"` shape as an attendee so downstream normalisers can
  # treat the two alike, or `nil` when the property is absent.
  defp extract_organizer(lines) do
    line =
      Enum.find(lines, fn line ->
        String.starts_with?(line, "ORGANIZER:") or String.starts_with?(line, "ORGANIZER;")
      end)

    case line do
      nil -> nil
      line -> %{"email" => calendar_user_address(line), "name" => common_name(line)}
    end
  end

  defp parse_attendee_line(line) do
    %{
      "email" => calendar_user_address(line),
      "name" => common_name(line),
      "status" => partstat(line)
    }
  end

  defp calendar_user_address(line) do
    case Regex.run(~r/:mailto:(.+)$/i, line) do
      [_match, addr] -> String.trim(addr)
      nil -> nil
    end
  end

  defp common_name(line) do
    case Regex.run(~r/(?:^|;)CN=([^;:]+)/i, line) do
      [_match, cn] -> cn |> String.trim() |> String.trim("\"")
      nil -> nil
    end
  end

  defp partstat(line) do
    case Regex.run(~r/(?:^|;)PARTSTAT=([^;:]+)/i, line) do
      [_match, status] -> status |> String.trim() |> String.downcase()
      nil -> nil
    end
  end

  defp extract_recurrence_id(lines) do
    line =
      Enum.find(lines, fn line ->
        String.starts_with?(line, "RECURRENCE-ID:") or
          String.starts_with?(line, "RECURRENCE-ID;")
      end)

    case line do
      nil -> nil
      line -> line |> String.split(":", parts: 2) |> List.last() |> String.trim()
    end
  end

  # RFC 5545 §3.2.13 — `RANGE=THISANDFUTURE` on a `RECURRENCE-ID` means the
  # override applies to the targeted instance *and every later instance*, not
  # just the single occurrence. Only the parametered form (`RECURRENCE-ID;…`)
  # can carry it; the bare `RECURRENCE-ID:` form never does. Returns
  # `:this_and_future` or `nil`.
  defp extract_recurrence_id_range(lines) do
    line = Enum.find(lines, &String.starts_with?(&1, "RECURRENCE-ID;"))

    with line when is_binary(line) <- line,
         params = line |> String.split(":", parts: 2) |> List.first(),
         true <- Regex.match?(~r/(?:^|;)RANGE=THISANDFUTURE/i, params) do
      :this_and_future
    else
      _no_range -> nil
    end
  end

  defp normalize_transp("TRANSPARENT"), do: "transparent"
  defp normalize_transp("OPAQUE"), do: "opaque"
  defp normalize_transp(other), do: other

  defp extract_property(lines, property_name) do
    line =
      Enum.find(lines, fn line ->
        String.starts_with?(line, property_name <> ":") or
          String.starts_with?(line, property_name <> ";")
      end)

    case line do
      nil ->
        nil

      line ->
        line
        |> String.split(":", parts: 2)
        |> List.last()
        |> decode_value()
    end
  end

  defp extract_datetime_property(lines, property_name) do
    line =
      Enum.find(lines, fn line ->
        String.starts_with?(line, property_name <> ":") or
          String.starts_with?(line, property_name <> ";")
      end)

    case line do
      nil ->
        nil

      line ->
        # Extract timezone parameter if present
        timezone = extract_timezone_param(line)

        # Extract the datetime value
        value =
          line
          |> String.split(":", parts: 2)
          |> List.last()
          |> String.trim()

        %{value: value, timezone: timezone}
    end
  end

  # RFC 5545 §3.2.18 permits both quoted (`TZID="Europe/Brussels"`) and
  # unquoted (`TZID=Europe/Brussels`) forms. Zimbra emits the quoted form;
  # Sabre/vobject, Radicale pass-through, and Tymeslot's own writer emit
  # unquoted. `Timezones.sanitize/1` handles both, plus Windows zone names
  # that can leak in through user-imported ICS files.
  defp extract_timezone_param(line) do
    case Regex.run(~r/TZID=([^;:]+)/, line) do
      [_match, timezone] -> Timezones.sanitize(timezone)
      nil -> nil
    end
  end

  defp decode_value(value) do
    value
    |> String.trim()
    |> String.replace("\\n", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end

  defp parse_datetime_property(nil, _vtimezones), do: nil

  defp parse_datetime_property(%{value: value, timezone: timezone} = dt_info, vtimezones) do
    if vtimezone_override?(timezone, vtimezones) do
      resolve_via_vtimezone(value, timezone, vtimezones)
    else
      case ICal.parse_datetime_with_timezone(dt_info) do
        {:ok, datetime} -> datetime
        # Fallback for all-day or basic date formats (YYYYMMDD)
        {:error, _reason} -> all_day_date(value)
      end
    end
  end

  # A bundled VTIMEZONE only takes precedence when the TZID is one the
  # configured time zone database cannot resolve. Genuine IANA zones (and the
  # `Etc/GMT∓N` zones `Timezones.sanitize/1` maps offset TZIDs to) keep the
  # richer database-backed conversion, including full DST history.
  defp vtimezone_override?(timezone, vtimezones) when is_binary(timezone),
    do: Map.has_key?(vtimezones, timezone) and not tz_database_known?(timezone)

  defp vtimezone_override?(_timezone, _vtimezones), do: false

  defp resolve_via_vtimezone(value, timezone, vtimezones) do
    with {:ok, %NaiveDateTime{} = naive} <- ICal.parse_ical_datetime(value),
         {:ok, vtz} <- Map.fetch(vtimezones, timezone),
         {:ok, datetime} <- VTimezone.to_utc(vtz, naive) do
      datetime
    else
      _unresolved -> all_day_date(value)
    end
  end

  # Probes the configured time zone database at a fixed, transition-free instant
  # so a known zone never reports as unknown via a DST gap/ambiguity result.
  defp tz_database_known?(timezone) do
    case DateTime.from_naive(~N[2020-06-15 12:00:00], timezone) do
      {:error, _reason} -> false
      _resolved -> true
    end
  end

  defp all_day_date(value) do
    with true <- is_binary(value),
         true <- String.match?(value, ~r/^\d{8}$/),
         <<y1::binary-size(4), m1::binary-size(2), d1::binary-size(2)>> <- value,
         {year, ""} <- Integer.parse(y1),
         {month, ""} <- Integer.parse(m1),
         {day, ""} <- Integer.parse(d1),
         {:ok, date} <- Date.new(year, month, day) do
      date
    else
      _error -> nil
    end
  end

  defp calculate_end_time(nil, _duration), do: nil

  # Default 1 hour for DateTime, 1 day for Date
  defp calculate_end_time(%DateTime{} = start_time, nil),
    do: DateTime.add(start_time, 3600, :second)

  defp calculate_end_time(%Date{} = start_time, nil), do: Date.add(start_time, 1)

  defp calculate_end_time(%DateTime{} = start_time, duration_str) do
    # Parse ISO 8601 duration (simplified - only handles basic cases)
    case Duration.parse(duration_str) do
      {:ok, seconds} -> DateTime.add(start_time, seconds, :second)
      {:error, _reason} -> DateTime.add(start_time, 3600, :second)
    end
  end

  defp calculate_end_time(%Date{} = start_time, duration_str) do
    # For all-day events with duration, we calculate the number of days.
    # RFC 5545 durations like PT1H30M or P1D
    case Duration.parse(duration_str) do
      {:ok, seconds} ->
        # Convert seconds to days, rounding up to at least 1 day
        days = div(seconds, 86_400)
        Date.add(start_time, max(days, 1))

      {:error, _reason} ->
        # Fallback to 1 day
        Date.add(start_time, 1)
    end
  end

  defp extract_exdates(lines, vtimezones) do
    lines
    |> Enum.filter(fn line ->
      String.starts_with?(line, "EXDATE:") or String.starts_with?(line, "EXDATE;")
    end)
    |> Enum.flat_map(fn line ->
      timezone = extract_timezone_param(line)
      value = line |> String.split(":", parts: 2) |> List.last() |> String.trim()

      value
      |> String.split(",")
      |> Enum.map(fn str ->
        parse_datetime_property(%{value: String.trim(str), timezone: timezone}, vtimezones)
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp extract_calendars_from_xml(xml_body) do
    # Pattern to extract calendar data from CalDAV response
    # Namespace prefixes vary by server (C:, cal:, caldav:, etc.)
    calendar_data_pattern =
      ~r/<(?:[a-zA-Z]+:)?calendar-data[^>]*>(.*?)<\/(?:[a-zA-Z]+:)?calendar-data>/s

    Enum.map(Regex.scan(calendar_data_pattern, xml_body), fn [_match, calendar_data] ->
      # Unescape XML entities
      calendar_data
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
    end)
  end
end
