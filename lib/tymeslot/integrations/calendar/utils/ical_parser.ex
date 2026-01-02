defmodule Tymeslot.Integrations.Calendar.ICalParser do
  @moduledoc """
  Robust iCal/vCalendar parser that handles various edge cases and formats.
  Replaces the problematic 'magical' library with a custom implementation.
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Utils.DateTimeUtils

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
        _ -> 0
      end

    Metrics.track_parsing_performance(:ical, size, duration_ms, event_count)

    result
  rescue
    error ->
      Logger.error("Failed to parse iCal content: #{inspect(error)}")
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
      {:error, _} -> []
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
    now = DateTime.utc_now()

    content
    |> extract_vevent_blocks()
    |> Enum.map(&parse_event_block/1)
    |> Enum.filter(fn event ->
      # Only include valid events that haven't ended yet
      event != nil && event.end_time && DateTime.compare(event.end_time, now) != :lt
    end)
  end

  defp extract_vevent_blocks(content) do
    content
    |> String.split("BEGIN:VEVENT")
    |> Enum.drop(1)
    |> Enum.map(fn block ->
      case String.split(block, "END:VEVENT", parts: 2) do
        [event_content | _] -> "BEGIN:VEVENT\n" <> event_content <> "\nEND:VEVENT"
        _ -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp parse_event_block(event_block) do
    lines = unfold_lines(event_block)

    # Extract properties
    uid = extract_property(lines, "UID")
    summary = extract_property(lines, "SUMMARY")
    description = extract_property(lines, "DESCRIPTION")
    location = extract_property(lines, "LOCATION")

    # Parse dates with timezone support
    dtstart = extract_datetime_property(lines, "DTSTART")
    dtend = extract_datetime_property(lines, "DTEND")

    start_time = parse_datetime_property(dtstart)

    end_time =
      parse_datetime_property(dtend) ||
        calculate_end_time(start_time, extract_property(lines, "DURATION"))

    if uid && summary && start_time do
      %{
        uid: uid,
        summary: summary,
        description: description,
        location: location,
        start_time: start_time,
        end_time: end_time
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

  defp unfold_lines(content) do
    content
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      # Continuation line (starts with space or tab)
      if String.match?(line, ~r/^[\s\t]/) && acc != [] do
        [last | rest] = acc
        # Add a space between the folded lines
        [last <> " " <> String.trim_leading(line) | rest]
      else
        # New line
        [line | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp extract_property(lines, property_name) do
    case Enum.find(lines, &String.starts_with?(&1, property_name <> ":")) do
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

  defp extract_timezone_param(line) do
    case Regex.run(~r/TZID=([^;:]+)/, line) do
      [_, timezone] -> timezone
      _ -> nil
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

  defp parse_datetime_property(nil), do: nil

  defp parse_datetime_property(dt_info) do
    case DateTimeUtils.parse_datetime_with_timezone(dt_info) do
      {:ok, datetime} ->
        datetime

      {:error, _} ->
        # Fallback for all-day or basic date formats (YYYYMMDD)
        with %{value: value} <- dt_info,
             true <- is_binary(value),
             true <- String.match?(value, ~r/^\d{8}$/),
             <<y1::binary-size(4), m1::binary-size(2), d1::binary-size(2)>> <- value,
             {year, ""} <- Integer.parse(y1),
             {month, ""} <- Integer.parse(m1),
             {day, ""} <- Integer.parse(d1),
             {:ok, date} <- Date.new(year, month, day),
             {:ok, dt} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
          dt
        else
          _ -> nil
        end
    end
  end

  defp calculate_end_time(nil, _), do: nil
  # Default 1 hour
  defp calculate_end_time(start_time, nil), do: DateTime.add(start_time, 3600, :second)

  defp calculate_end_time(start_time, duration_str) do
    # Parse ISO 8601 duration (simplified - only handles basic cases)
    case DateTimeUtils.parse_duration(duration_str) do
      {:ok, seconds} -> DateTime.add(start_time, seconds, :second)
      _ -> DateTime.add(start_time, 3600, :second)
    end
  end

  defp extract_calendars_from_xml(xml_body) do
    # Pattern to extract calendar data from CalDAV response
    calendar_data_pattern = ~r/<(?:C:)?calendar-data[^>]*>(.*?)<\/(?:C:)?calendar-data>/s

    Enum.map(Regex.scan(calendar_data_pattern, xml_body), fn [_, calendar_data] ->
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
