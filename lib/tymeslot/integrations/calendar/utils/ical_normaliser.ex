defmodule Tymeslot.Integrations.Calendar.ICalNormaliser do
  @moduledoc """
  Normalises parsed iCalendar events into canonical `CalendarEvent` structs.

  Shared by every provider whose events arrive as iCalendar rather than as a
  vendor API payload: CalDAV (via `Tymeslot.Integrations.Calendar.CalDAV.EventProcessor`)
  and subscribed ICS feeds (via `Tymeslot.Integrations.Calendar.Ics.Provider`).
  Both hand it the map shape `Tymeslot.Integrations.Calendar.ICalParser` emits,
  so the timing, recurrence, and field mapping rules live here once instead of
  once per provider. Recurrence expansion lives in
  `Tymeslot.Integrations.Calendar.ICalNormaliser.Expansion`, whose moduledoc
  documents the `_recurring`, `_occ_start`/`_occ_end` and `_uid_suffix`
  markers this module reads when it builds each event.

  The provider atom is threaded through rather than inferred: it lands on each
  `CalendarEvent` and in the skip diagnostics, and it is the only thing that
  differs between callers.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.CalDAV.HostAddresses
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalNormaliser.Expansion
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.InvalidEventReport
  alias Tymeslot.Integrations.Calendar.Reminder
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Utils.DateTimeUtils.Duration
  alias Tymeslot.Utils.MapKeys

  @duration_defaulted "unreadable DURATION, kept with the default length"

  @doc """
  Expands and normalises `raw_events` into `CalendarEvent` structs.

  Events that fail validation are skipped, logged, and recorded with
  `InvalidEventReport`, so one malformed entry never costs a whole sync and the
  sync run raises one operator alert for all of them. An event whose DURATION
  could not be read is kept with the parser's default length, and logged and
  recorded the same way.
  """
  @spec normalise_events([map()], map(), atom()) :: {:ok, [CalendarEvent.t()]}
  def normalise_events(raw_events, context, provider) do
    # Recurring events are expanded over the sync window every provider
    # reads, so a stored occurrence never falls outside the range the
    # calendar grid and availability checks read back.
    {range_start, range_end} = Sync.window()

    {events, defaulted} =
      raw_events
      |> HostAddresses.mark_declined(Map.get(context, :host_addresses, []))
      |> Expansion.expand_all(range_start, range_end)
      |> Enum.reduce({[], %{}}, fn raw, {acc, defaulted} ->
        case build_calendar_event(raw, context, provider) do
          {:ok, event} ->
            {[event | acc], note_default(defaulted, raw)}

          {:error, reason} ->
            record_skip(raw, context, provider, reason)
            {acc, defaulted}
        end
      end)

    defaulted |> Map.values() |> Enum.each(&record_default(&1, context, provider))

    {:ok, Enum.reverse(events)}
  end

  # A VEVENT kept with a default duration is reported once, however many
  # occurrences it expands to, and only when it was kept: one skipped for
  # another reason is reported as skipped alone.
  defp note_default(defaulted, %{duration_defaulted: true} = raw),
    do: Map.put_new(defaulted, {raw[:uid], raw[:recurrence_id]}, raw)

  defp note_default(defaulted, _raw), do: defaulted

  defp record_skip(raw, context, provider, reason) do
    Logger.warning("Skipping invalid calendar event",
      provider: provider,
      reason: reason,
      event_uid: raw[:uid],
      calendar_integration_id: context.calendar_integration_id
    )

    InvalidEventReport.record(provider, context, raw[:uid], reason)
  end

  defp record_default(raw, context, provider) do
    Logger.warning("Calendar event kept with a default duration",
      provider: provider,
      reason: @duration_defaulted,
      event_uid: raw[:uid],
      calendar_integration_id: context.calendar_integration_id
    )

    InvalidEventReport.record_default(provider, context, raw[:uid], @duration_defaulted)
  end

  @doc """
  The reminders the sync caches for the master event of a stored document,
  or `:error` when the document does not parse to exactly one master.

  The master is the one VEVENT without a `RECURRENCE-ID`: a recurring
  series' resource also holds a VEVENT per edited occurrence, and those carry
  alarms of their own. It is the VEVENT `ICalBuilder.Patcher` edits, so its
  alarms are the ones a patch would replace.
  """
  @spec document_reminders(String.t()) :: {:ok, [Reminder.t()]} | :error
  def document_reminders(document) when is_binary(document) do
    with {:ok, events} <- ICalParser.parse(document),
         [master] <- Enum.reject(events, &Expansion.override?/1) do
      {:ok, map_reminders(master[:valarm])}
    else
      _other -> :error
    end
  end

  @doc "See `Tymeslot.Integrations.Calendar.ICalNormaliser.Expansion.expand_occurrences/3`."
  defdelegate expand_occurrences(raw_events, range_start, range_end), to: Expansion

  @doc "See `Tymeslot.Integrations.Calendar.ICalNormaliser.Expansion.occurrence_key/2`."
  defdelegate occurrence_key(value, timezone), to: Expansion

  # The canonical CalendarEvent schema stores recurrence_exceptions as
  # `{:array, :date}`, while EXDATE values from the iCal parser are DateTimes
  # (the recurrence expander needs them as DateTimes for occurrence comparison).
  # Convert at the storage boundary.
  defp exdates_as_dates(exdates) when is_list(exdates) do
    Enum.map(exdates, fn
      %DateTime{} = dt -> DateTime.to_date(dt)
      %Date{} = d -> d
    end)
  end

  defp exdates_as_dates(_other), do: []

  defp build_calendar_event(raw, context, provider) do
    {all_day, start_val, end_val, timezone} = resolve_timing(raw)

    attrs =
      %{
        uid: build_uid(raw),
        provider: provider,
        calendar_integration_id: context.calendar_integration_id,
        provider_calendar_id: calendar_id_for(raw, context),
        provider_event_id: raw[:href] || raw[:uid],
        synced_at: context.synced_at,
        summary: raw[:summary],
        description: raw[:description],
        location: raw[:location],
        visibility: map_visibility(raw[:class]),
        transparency: map_transparency(raw[:transparency]),
        status: map_status(raw[:status]),
        organiser: map_organiser(raw[:organizer]),
        attendees: map_attendees(raw[:attendee] || raw[:attendees]),
        reminders: map_reminders(raw[:valarm]),
        recurrence_rule: raw[:rrule] || raw[:recurrence_rule],
        recurrence_exceptions: exdates_as_dates(raw[:exdate] || raw[:exdates] || []),
        recurrence_id: raw[:recurrence_id],
        recurrence_id_range: raw[:recurrence_id_range],
        etag: raw[:etag],
        colour: EventColour.nearest_key(raw[:colour]),
        provider_metadata:
          Map.drop(raw, [:raw_ical, :href, :duration_defaulted | Expansion.marker_keys()]),
        raw_ical: raw[:raw_ical],
        created_by_tymeslot: tymeslot_origin?(raw)
      }
      |> Map.merge(timing_fields(all_day, start_val, end_val))
      |> maybe_put_timezone(timezone)

    CalendarEvent.new(attrs)
  end

  # A CalDAV batch can span several collections, but the sync builds one context
  # for the whole batch, so `context.provider_calendar_id` is only ever the
  # integration's first path. The event's href is rooted at the collection it
  # actually lives in, which makes it the authoritative signal; match it against
  # the paths the integration knows rather than parsing it, so a server whose
  # hrefs are shaped unexpectedly falls back instead of inventing a calendar.
  # Longest match wins: CalDAV collections can nest, and the deepest one is the
  # collection the event belongs to. ICS feeds carry no paths and keep the
  # context value, which is correct — a subscription is a single calendar.
  defp calendar_id_for(%{href: href}, context) when is_binary(href) do
    case matching_paths(href, context) do
      [] -> context.provider_calendar_id
      paths -> Enum.max_by(paths, &byte_size/1)
    end
  end

  defp calendar_id_for(_raw, context), do: context.provider_calendar_id

  defp matching_paths(href, context) do
    context
    |> Map.get(:calendar_paths, [])
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(href, &1)))
  end

  # --- Timing resolution ---

  defp resolve_timing(%{_recurring: true} = raw) do
    # Expanded occurrence — times come from RecurrenceExpander
    occ_start = raw[:_occ_start]
    occ_end = raw[:_occ_end]
    resolve_timing_values(occ_start, occ_end)
  end

  # The parser hands DTSTART over in UTC, so an event that is not expanded (a
  # one-off, or an occurrence override) is put back in its own zone first, as
  # `Expansion` does for a master: the zone its start carries is the one
  # the row records, and a row that recorded UTC for a Berlin event would have
  # its next edit written as a UTC wall clock under the Berlin TZID.
  defp resolve_timing(raw) do
    start_val = Expansion.in_event_zone(raw[:dtstart] || raw[:start_time], raw[:timezone])
    end_val = raw[:dtend] || raw[:end_time]
    resolve_timing_values(start_val, end_val)
  end

  defp resolve_timing_values(start_val, end_val) do
    cond do
      is_struct(start_val, Date) ->
        # RFC 5545 §3.8.2.2: when DTEND is absent for a DATE-valued event,
        # it defaults to DTSTART + P1D (one day later).
        effective_end = end_date(end_val) || Date.add(start_val, 1)
        {true, start_val, effective_end, nil}

      radicale_all_day?(start_val, end_val) ->
        {true, DateTime.to_date(start_val), DateTime.to_date(end_val), nil}

      is_struct(start_val, DateTime) ->
        tz = start_val.time_zone
        {false, DateTime.shift_zone!(start_val, "Etc/UTC"), end_datetime(end_val, tz), tz}

      true ->
        {false, start_val, end_val, nil}
    end
  end

  # RFC 5545 §3.8.2.2 requires DTSTART and DTEND to share a value type, but
  # producers do emit a `VALUE=DATE` DTSTART against a `DATE-TIME` DTEND (and the
  # reverse). The iCal parser types each property independently, so the mismatch
  # reaches here intact. DTSTART decides the representation and DTEND is
  # converted to match; otherwise the event carries a `%DateTime{}` in a `:date`
  # column (or the reverse) and is dropped by `CalendarEvent.validate_timing/1`.
  #
  # DTEND is exclusive in both representations, so the conversions preserve the
  # instant the event stops blocking: a DTEND carrying a time of day rounds up to
  # the following date rather than truncating away that final part-day.
  defp end_date(nil), do: nil
  defp end_date(%Date{} = date), do: date

  defp end_date(%DateTime{} = dt) do
    date = DateTime.to_date(dt)

    if Time.compare(DateTime.to_time(dt), ~T[00:00:00]) == :eq do
      date
    else
      Date.add(date, 1)
    end
  end

  defp end_datetime(%DateTime{} = dt, _timezone), do: DateTime.shift_zone!(dt, "Etc/UTC")

  # A DATE-valued DTEND carries no zone, so it means midnight local to the event
  # and is resolved in DTSTART's zone. Reading it as UTC instead would end the
  # event early anywhere east of Greenwich, freeing time the user is still busy.
  # A DST transition can leave that midnight ambiguous or missing; both take the
  # later instant, which keeps the longer of the two readings blocked.
  defp end_datetime(%Date{} = date, timezone) do
    case DateTime.new(date, ~T[00:00:00], timezone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, _first, second} -> DateTime.shift_zone!(second, "Etc/UTC")
      {:gap, _just_before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp end_datetime(other, _timezone), do: other

  # A moment at midnight (DTSTART with no end) is not a whole day.
  defp radicale_all_day?(same, same), do: false

  defp radicale_all_day?(
         %DateTime{hour: 0, minute: 0, second: 0, time_zone: "Etc/UTC"},
         %DateTime{hour: 0, minute: 0, second: 0, time_zone: "Etc/UTC"}
       ),
       do: true

  defp radicale_all_day?(_start, _end), do: false

  defp timing_fields(true, start_date, end_date) do
    %{all_day: true, start_date: start_date, end_date: end_date}
  end

  defp timing_fields(false, start_at, end_at) do
    %{all_day: false, start_at: start_at, end_at: end_at}
  end

  defp maybe_put_timezone(attrs, nil), do: attrs
  defp maybe_put_timezone(attrs, tz), do: Map.put(attrs, :timezone, tz)

  # --- UID generation ---

  defp build_uid(%{_uid_suffix: suffix} = raw) when is_binary(suffix),
    do: "#{raw[:uid]}_#{suffix}"

  defp build_uid(raw), do: raw[:uid]

  # --- Field mappers ---

  defp tymeslot_origin?(raw), do: Format.uid_origin(raw[:uid]) == :tymeslot

  defp map_visibility("PUBLIC"), do: :public
  defp map_visibility("PRIVATE"), do: :private
  defp map_visibility("CONFIDENTIAL"), do: :confidential
  defp map_visibility(_other), do: nil

  defp map_transparency("TRANSPARENT"), do: :transparent
  defp map_transparency("transparent"), do: :transparent
  defp map_transparency(_other), do: :opaque

  defp map_status("CONFIRMED"), do: :confirmed
  defp map_status("TENTATIVE"), do: :tentative
  defp map_status("CANCELLED"), do: :cancelled
  # Not an iCalendar STATUS value: set by `CalDAV.HostAddresses` on an event
  # the host declined.
  defp map_status("DECLINED"), do: :declined
  defp map_status(_other), do: :confirmed

  defp map_organiser(nil), do: nil

  defp map_organiser(organiser) when is_map(organiser) do
    %{
      email: MapKeys.get(organiser, :email),
      display_name: organiser["CN"] || organiser["name"] || organiser[:display_name]
    }
  end

  defp map_organiser(organiser) when is_binary(organiser) do
    email =
      case Regex.run(~r/mailto:(.+)/i, organiser) do
        [_match, addr] -> String.trim(addr)
        nil -> organiser
      end

    %{email: email, display_name: nil}
  end

  defp map_organiser(_other), do: nil

  defp map_attendees(nil), do: []
  defp map_attendees(attendees) when is_list(attendees), do: Enum.map(attendees, &map_attendee/1)
  defp map_attendees(_other), do: []

  # `ICalParser` is the only producer: it has already read the `CN` and
  # `PARTSTAT` parameters off the `ATTENDEE` line into `"name"` and a
  # lower-cased `"status"`, so those are the only spellings that arrive.
  defp map_attendee(a) when is_map(a) do
    Attendee.new(
      email: a["email"],
      display_name: a["name"],
      response_status: map_partstat(a["status"])
    )
  end

  defp map_attendee(_other), do: Attendee.new([])

  # RFC 5545 §3.2.12: an absent PARTSTAT means NEEDS-ACTION, and DELEGATED is
  # not a reply any provider can carry.
  defp map_partstat("accepted"), do: :accepted
  defp map_partstat("declined"), do: :declined
  defp map_partstat("tentative"), do: :tentative
  defp map_partstat(_other), do: :needs_action

  @doc """
  The reminder the sync reads from one VALARM, given as its unfolded content
  lines, or `nil` for an alarm a reminder cannot express.

  `ICalBuilder.Patcher` matches a document's alarms to an edit's reminders
  with it, so an alarm is recognised by exactly the reading the sync cached
  for it, approximations included.
  """
  @spec alarm_reminder([String.t()]) :: Reminder.t() | nil
  def alarm_reminder(lines) when is_list(lines),
    do: lines |> ICalParser.parse_alarm() |> map_alarm() |> List.first()

  # A reminder is a lead time before the start, so only an alarm whose
  # TRIGGER is a duration relative to the start, at or before it, maps to
  # one. An alarm at a fixed time, relative to the end, or after the start is
  # left out of the cache; the server's copy keeps it, because a write keeps
  # every alarm a reminder cannot express.
  defp map_reminders(alarms) when is_list(alarms), do: Enum.flat_map(alarms, &map_alarm/1)
  defp map_reminders(_other), do: []

  defp map_alarm(%{trigger: trigger, trigger_related: "START", trigger_value: "DURATION"} = alarm)
       when is_binary(trigger) do
    case Duration.parse_signed(trigger) do
      {:ok, seconds} when seconds <= 0 ->
        [%{method: alarm_method(alarm[:action]), minutes_before: div(-seconds, 60)}]

      _after_start_or_unreadable ->
        []
    end
  end

  defp map_alarm(_other), do: []

  defp alarm_method(action) when is_binary(action) do
    if String.upcase(action) == "EMAIL", do: :email, else: :popup
  end

  defp alarm_method(_no_action), do: :popup
end
