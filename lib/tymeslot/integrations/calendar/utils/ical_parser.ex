defmodule Tymeslot.Integrations.Calendar.ICalParser do
  @moduledoc """
  Robust iCal/vCalendar parser that handles various edge cases and formats.
  Replaces the problematic 'magical' library with a custom implementation.
  """

  require Logger
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.VTimezone
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils
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
      Logger.error("Failed to parse iCal content", error: LogFormat.reason(error))
      {:error, "Parse error: #{inspect(error)}"}
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
    {lines, subcomponents} = event_block |> LineFolder.unfold_lines() |> split_subcomponents()

    # Extract properties
    uid = extract_property(lines, "UID")
    recurrence_rule = extract_property(lines, "RRULE")
    recurrence_id = extract_recurrence_id(lines)
    exdates = extract_date_list(lines, "EXDATE", vtimezones)

    # Parse dates with timezone support
    dtstart = extract_datetime_property(lines, "DTSTART")
    dtend = extract_datetime_property(lines, "DTEND")

    start_time = parse_datetime_property(dtstart, vtimezones)

    {end_time, duration_defaulted} =
      case parse_datetime_property(dtend, vtimezones) do
        nil ->
          duration = extract_property(lines, "DURATION")
          calculate_end_time(start_time, duration, dtstart, vtimezones)

        dtend_time ->
          {dtend_time, false}
      end

    if uid && start_time do
      lines
      |> descriptive_properties()
      |> Map.merge(%{
        uid: uid,
        recurrence_rule: recurrence_rule,
        recurrence_id: recurrence_id,
        recurrence_id_range: extract_recurrence_id_range(lines),
        # A RECURRENCE-ID carrying its own TZID, resolved to UTC as DTSTART is
        # (through the file's VTIMEZONE for a zone the database lacks). `nil`
        # for the UTC, floating and DATE forms, which `recurrence_id` above
        # already says all there is to say about.
        recurrence_id_at: zoned_recurrence_id(lines, vtimezones),
        exdates: exdates,
        # Occurrences added beside the rule's (RFC 5545 §3.8.5.2); a PERIOD
        # value names no start this parser reads and is left out.
        rdates: extract_date_list(lines, "RDATE", vtimezones),
        start_time: start_time,
        end_time: end_time,
        # A DURATION that could not be read, so `end_time` is the default
        # length instead: an hour for a timed event, a day for an all-day one.
        # The normaliser reports it, as it reports the events it skips.
        duration_defaulted: duration_defaulted,
        # The DTSTART TZID as written on the wire, already sanitised to an IANA
        # name. `start_time`/`end_time` above are converted to UTC, which throws
        # the zone away — recurring events need it back to expand occurrences in
        # local wall-clock time across a DST transition (see
        # `Tymeslot.Integrations.Calendar.ICalNormaliser.expand_occurrences/3`).
        # `nil` for UTC, floating, and DATE-valued events, none of which have a
        # zone to restore.
        timezone: dtstart_timezone(dtstart),
        # A DTSTART with neither a TZID nor a `Z` is a floating wall-clock time,
        # which `start_time`/`end_time` above read as UTC. Kept so a caller that
        # knows whose wall clock it is can place it there.
        floating: floating?(dtstart),
        # The event's VALARMs, as written: each alarm's ACTION and TRIGGER,
        # which the normaliser maps to the reminders it can represent.
        valarm: extract_alarms(subcomponents)
      })
    else
      Logger.debug("Skipping event with missing required fields",
        uid: uid,
        summary: extract_property(lines, "SUMMARY"),
        has_start: !is_nil(start_time)
      )

      nil
    end
  end

  # What the event says about itself, beside its identity and timing.
  defp descriptive_properties(lines) do
    %{
      summary: extract_property(lines, "SUMMARY"),
      description: extract_property(lines, "DESCRIPTION"),
      location: extract_property(lines, "LOCATION"),
      organizer: extract_organizer(lines),
      attendees: extract_attendees(lines),
      transparency: normalize_transp(extract_property(lines, "TRANSP")),
      status: extract_property(lines, "STATUS"),
      class: extract_property(lines, "CLASS"),
      colour:
        extract_property(lines, "COLOR") || extract_property(lines, "X-APPLE-CALENDAR-COLOR")
    }
  end

  # A VEVENT's subcomponents (its VALARMs, and RFC 9073's PARTICIPANT or
  # VLOCATION) reuse the event's property names: RFC 5545 §3.6.6 requires a
  # DESCRIPTION on a DISPLAY alarm. They are lifted out by nesting depth
  # before any property is matched, so that a property found in what remains
  # is the event's own, whether it comes before or after the alarm.
  defp split_subcomponents([event_begin | rest]),
    do: split_subcomponents(rest, [event_begin], [])

  defp split_subcomponents([], properties, components),
    do: {Enum.reverse(properties), Enum.reverse(components)}

  defp split_subcomponents([line | rest] = lines, properties, components) do
    if component_boundary?(line, "BEGIN:") do
      {component, remaining} = take_component(lines, 0, [])
      split_subcomponents(remaining, properties, [component | components])
    else
      split_subcomponents(rest, [line | properties], components)
    end
  end

  # Takes one component, nested ones included, up to its matching END. An
  # unterminated component runs to the end of the event block.
  defp take_component([], _depth, acc), do: {Enum.reverse(acc), []}

  defp take_component([line | rest], depth, acc) do
    depth =
      cond do
        component_boundary?(line, "BEGIN:") -> depth + 1
        component_boundary?(line, "END:") -> depth - 1
        true -> depth
      end

    if depth == 0,
      do: {Enum.reverse([line | acc]), rest},
      else: take_component(rest, depth, [line | acc])
  end

  defp component_boundary?(line, marker),
    do: line |> String.upcase() |> String.starts_with?(marker)

  defp extract_alarms(components) do
    for [first | _rest] = lines <- components, String.upcase(first) == "BEGIN:VALARM" do
      parse_alarm(lines)
    end
  end

  @doc """
  Reads one VALARM, given as its unfolded content lines, into the map
  `parse/1` lists under an event's `:valarm`: its `ACTION` and its `TRIGGER`
  with the trigger's `RELATED` and `VALUE` parameters.
  """
  @spec parse_alarm([String.t()]) :: map()
  def parse_alarm(lines) when is_list(lines) do
    trigger = extract_datetime_property(lines, "TRIGGER")

    %{
      action: extract_property(lines, "ACTION"),
      trigger: trigger && trigger.value,
      trigger_related: trigger_param(lines, "RELATED", "START"),
      trigger_value: trigger_param(lines, "VALUE", "DURATION")
    }
  end

  # RFC 5545 §3.8.6.3: TRIGGER is relative to the start unless RELATED=END,
  # and a duration unless VALUE=DATE-TIME.
  defp trigger_param(lines, param, default) do
    with line when is_binary(line) <- Enum.find(lines, &property_line?(&1, "TRIGGER")),
         [params | _value] <- String.split(line, ":", parts: 2),
         [_match, value] <- Regex.run(~r/;#{param}=([^;]+)/i, params) do
      String.upcase(value)
    else
      _absent -> default
    end
  end

  defp property_line?(line, property_name),
    do:
      String.starts_with?(line, property_name <> ":") or
        String.starts_with?(line, property_name <> ";")

  defp dtstart_timezone(%{timezone: timezone}) when is_binary(timezone), do: timezone
  defp dtstart_timezone(_dtstart), do: nil

  defp floating?(%{value: value, timezone: nil}),
    do: Regex.match?(~r/T\d{6}$/, String.trim(value))

  defp floating?(_dtstart), do: false

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

  defp zoned_recurrence_id(lines, vtimezones) do
    case extract_datetime_property(lines, "RECURRENCE-ID") do
      %{timezone: zone} = rid when is_binary(zone) -> parse_datetime_property(rid, vtimezones)
      _no_zone -> nil
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
      Enum.find(lines, &property_line?(&1, property_name))

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
      Enum.find(lines, &property_line?(&1, property_name))

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

  # RFC 5545 §3.3.11, in one pass: each escape is read once, so the escaped
  # backslash in `\\new` stays a backslash before "new" rather than becoming
  # a line break, and an uppercase `\N` is a line break too.
  defp decode_value(value), do: value |> String.trim() |> unescape_text("")

  defp unescape_text(<<"\\", char, rest::binary>>, acc) when char in [?n, ?N],
    do: unescape_text(rest, acc <> "\n")

  defp unescape_text(<<"\\", char, rest::binary>>, acc) when char in [?\\, ?;, ?,],
    do: unescape_text(rest, <<acc::binary, char>>)

  defp unescape_text(<<char, rest::binary>>, acc), do: unescape_text(rest, <<acc::binary, char>>)
  defp unescape_text(<<>>, acc), do: acc

  defp parse_datetime_property(nil, _vtimezones), do: nil

  defp parse_datetime_property(%{value: value, timezone: timezone}, vtimezones) do
    with {:ok, %NaiveDateTime{} = naive} <- ICal.parse_ical_datetime(value),
         {:ok, datetime} <- wall_clock_to_utc(naive, timezone, vtimezones) do
      datetime
    else
      # All-day (YYYYMMDD) values, and anything unreadable as nil
      _not_a_datetime -> all_day_date(value)
    end
  end

  # A wall-clock time in a property's TZID, as a UTC DateTime: through the
  # file's VTIMEZONE when it overrides the zone, else the time zone database.
  defp wall_clock_to_utc(naive, timezone, vtimezones) do
    if vtimezone_override?(timezone, vtimezones) do
      VTimezone.to_utc(Map.fetch!(vtimezones, timezone), naive)
    else
      DateTimeUtils.convert_to_utc(naive, timezone)
    end
  end

  # A bundled VTIMEZONE only takes precedence when the TZID is one the
  # configured time zone database cannot resolve. Genuine IANA zones (and the
  # `Etc/GMT∓N` zones `Timezones.sanitize/1` maps offset TZIDs to) keep the
  # richer database-backed conversion, including full DST history.
  defp vtimezone_override?(timezone, vtimezones) when is_binary(timezone),
    do: Map.has_key?(vtimezones, timezone) and not tz_database_known?(timezone)

  defp vtimezone_override?(_timezone, _vtimezones), do: false

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

  # The end an event's DTSTART and DURATION give when it has no DTEND, and
  # whether DURATION was unreadable so the default length stands in for it.
  defp calculate_end_time(nil, _duration, _dtstart, _vtimezones), do: {nil, false}

  # RFC 5545 §3.6.1: with neither DTEND nor DURATION, a DATE-TIME DTSTART
  # ends where it starts, and a DATE one takes up that whole day.
  defp calculate_end_time(%DateTime{} = start_time, nil, _dtstart, _vtimezones),
    do: {start_time, false}

  defp calculate_end_time(%Date{} = start_time, nil, _dtstart, _vtimezones),
    do: {Date.add(start_time, 1), false}

  # RFC 5545 §3.3.6: a duration's days are nominal and its time part exact,
  # so the days move DTSTART's wall-clock time on in its own zone (`P1D`
  # across a DST change is still the same time the next day), and only then
  # the hours, minutes and seconds are added as elapsed time.
  defp calculate_end_time(%DateTime{} = start_time, duration_str, dtstart, vtimezones) do
    case Duration.parse_nominal(duration_str) do
      {:ok, {days, seconds}} ->
        end_time =
          start_time
          |> add_nominal_days(days, dtstart, vtimezones)
          |> DateTime.add(seconds, :second)

        {end_time, false}

      {:error, _reason} ->
        {DateTime.add(start_time, 3600, :second), true}
    end
  end

  # An all-day event spans whole days: its time part counts in whole days too,
  # a part day rounding up (`PT48H` is two days, `P1DT12H` also two).
  defp calculate_end_time(%Date{} = start_time, duration_str, _dtstart, _vtimezones) do
    case Duration.parse_nominal(duration_str) do
      {:ok, {days, seconds}} ->
        days = days + div(seconds + 86_399, 86_400)
        {Date.add(start_time, max(days, 1)), false}

      {:error, _reason} ->
        {Date.add(start_time, 1), true}
    end
  end

  defp add_nominal_days(start_time, 0, _dtstart, _vtimezones), do: start_time

  defp add_nominal_days(start_time, days, %{value: value, timezone: timezone}, vtimezones) do
    with {:ok, %NaiveDateTime{} = naive} <- ICal.parse_ical_datetime(value),
         {:ok, end_time} <-
           wall_clock_to_utc(NaiveDateTime.add(naive, days, :day), timezone, vtimezones) do
      end_time
    else
      _unresolved -> DateTime.add(start_time, days, :day)
    end
  end

  # EXDATE and RDATE: any number of lines, each a comma-separated list, each
  # value read as DTSTART is (its TZID, VALUE=DATE, or UTC).
  defp extract_date_list(lines, property, vtimezones) do
    lines
    |> Enum.filter(fn line ->
      String.starts_with?(line, property <> ":") or String.starts_with?(line, property <> ";")
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
end
