defmodule Tymeslot.Integrations.Calendar.ICalNormaliser do
  @moduledoc """
  Normalises parsed iCalendar events into canonical `CalendarEvent` structs.

  Shared by every provider whose events arrive as iCalendar rather than as a
  vendor API payload: CalDAV (via `Tymeslot.Integrations.Calendar.CalDAV.EventProcessor`)
  and subscribed ICS feeds (via `Tymeslot.Integrations.Calendar.Ics.Provider`).
  Both hand it the map shape `Tymeslot.Integrations.Calendar.ICalParser` emits,
  so the timing, recurrence, and field mapping rules live here once instead of
  once per provider.

  The provider atom is threaded through rather than inferred: it lands on each
  `CalendarEvent` and in the skip diagnostics, and it is the only thing that
  differs between callers.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Utils.MapKeys

  # How far either side of now recurring events are expanded. Matches the
  # sync window every provider fetches, so a stored occurrence never falls
  # outside the range the calendar grid and availability checks read back.
  @expansion_past_days 365
  @expansion_future_days 365

  @doc """
  Expands and normalises `raw_events` into `CalendarEvent` structs.

  Events that fail validation are skipped, logged, and reported through
  `AdminAlerts`, so one malformed entry never costs a whole sync.
  """
  @spec normalise_events([map()], map(), atom()) :: {:ok, [CalendarEvent.t()]}
  def normalise_events(raw_events, context, provider) do
    now = DateTime.utc_now()
    range_start = DateTime.add(now, -@expansion_past_days, :day)
    range_end = DateTime.add(now, @expansion_future_days, :day)
    overrides = index_overrides(raw_events)

    events =
      raw_events
      |> Enum.flat_map(&expand_event(&1, range_start, range_end, overrides))
      |> Enum.reduce([], fn raw, acc ->
        case build_calendar_event(raw, context, provider) do
          {:ok, event} ->
            [event | acc]

          {:error, reason} ->
            record_skip(raw, context, provider, reason)
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, events}
  end

  defp record_skip(raw, context, provider, reason) do
    Logger.warning("Skipping invalid calendar event",
      provider: provider,
      reason: reason,
      event_uid: raw[:uid],
      calendar_integration_id: context.calendar_integration_id
    )

    AdminAlerts.send_alert(:invalid_calendar_event, %{
      provider: provider,
      event_uid: raw[:uid],
      reason: reason,
      calendar_integration_id: context.calendar_integration_id
    })
  end

  # ---------------------------------------------------------------------------
  # Recurrence expansion
  # ---------------------------------------------------------------------------

  # A recurring event's CalDAV resource holds the master VEVENT plus one VEVENT
  # per occurrence that has been edited on its own, each carrying a
  # `RECURRENCE-ID` and no `RRULE`. They share the master's UID by RFC 5545, so
  # the pair `{uid, occurrence}` is what tells them apart. Indexed here once so
  # that expanding a master can skip the slots its overrides take over, rather
  # than generating an occurrence at the original time beside the edited one.
  defp index_overrides(raw_events) do
    for raw <- raw_events,
        override?(raw),
        key = override_key(raw),
        is_binary(key),
        into: MapSet.new(),
        do: {raw[:uid], key}
  end

  # A `RECURRENCE-ID` is what makes a VEVENT an override, whatever else it
  # carries. An override is never expanded: even one written with
  # `RANGE=THISANDFUTURE`, which replaces its occurrence and every later one,
  # is applied to its own slot only — the wider reading needs the master's rule
  # truncated as well and is not attempted here.
  defp override?(raw), do: is_binary(raw[:recurrence_id]) and raw[:recurrence_id] != ""

  defp override_key(raw), do: recurrence_id_suffix(raw[:recurrence_id], raw[:timezone])

  defp expand_event(raw, range_start, range_end, overrides) do
    rrule = raw[:rrule] || raw[:recurrence_rule]

    cond do
      override?(raw) ->
        # The override replaces the occurrence its `RECURRENCE-ID` names, so it
        # is identified by that slot and not by its own `DTSTART`: an override
        # that was itself rescheduled has a start that no longer matches the
        # occurrence it stands in for, and suffixing from it would file the row
        # beside that occurrence instead of over it. Its timing, summary and
        # the rest still come from its own properties.
        [Map.put(raw, :_uid_suffix, override_key(raw) || own_suffix(raw))]

      rrule && rrule != "" ->
        expand_series(raw, rrule, range_start, range_end, overrides)

      true ->
        [raw]
    end
  end

  defp expand_series(raw, rrule, range_start, range_end, overrides) do
    timezone = raw[:timezone]

    expander_event = %{
      start_time: in_event_zone(raw[:dtstart] || raw[:start_time], timezone),
      end_time: in_event_zone(raw[:dtend] || raw[:end_time], timezone),
      recurrence_rule: rrule
    }

    exdates = parse_exdates(raw[:exdate] || raw[:exdates] || [])

    expander_event
    |> RecurrenceExpander.expand(range_start, range_end, exdates: exdates)
    |> Enum.map(&{&1, occurrence_suffix(&1.start_time)})
    |> Enum.reject(fn {_occurrence, suffix} ->
      MapSet.member?(overrides, {raw[:uid], suffix})
    end)
    |> Enum.map(fn {occurrence, suffix} ->
      raw
      |> Map.put(:_occ_start, occurrence.start_time)
      |> Map.put(:_occ_end, occurrence.end_time)
      |> Map.put(:_recurring, true)
      |> Map.put(:_uid_suffix, suffix)
    end)
  end

  defp own_suffix(raw), do: occurrence_suffix(raw[:dtstart] || raw[:start_time])

  defp parse_exdates(exdates) when is_list(exdates), do: exdates
  defp parse_exdates(_other), do: []

  # `ICalParser` resolves DTSTART/DTEND to UTC and carries the TZID alongside,
  # so a recurring event would otherwise reach `RecurrenceExpander` as a bare
  # UTC instant. The expander advances each occurrence in the wall clock of
  # whatever zone its DateTime carries (see `shift_calendar_days/2` there), so a
  # UTC one keeps the master's original offset for the whole series: a weekly
  # event created in winter still lands an hour late once the clocks go forward.
  # Restoring the event's own zone first is what lets the expander re-resolve
  # the correct offset per occurrence. Falls back to the value as-is when there
  # is no zone to restore or it cannot be resolved, matching the expander's own
  # never-lose-an-occurrence policy.
  defp in_event_zone(%DateTime{} = datetime, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  defp in_event_zone(value, _timezone), do: value

  # The canonical CalendarEvent schema stores recurrence_exceptions as
  # `{:array, :date}`, while EXDATE values from the iCal parser are DateTimes
  # (the recurrence expander needs them as DateTimes for occurrence comparison).
  # Convert at the storage boundary.
  defp exdates_as_dates(exdates) do
    exdates
    |> parse_exdates()
    |> Enum.map(fn
      %DateTime{} = dt -> DateTime.to_date(dt)
      %Date{} = d -> d
    end)
  end

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
          Map.drop(raw, [
            :raw_ical,
            :href,
            :_occ_start,
            :_occ_end,
            :_recurring,
            :_uid_suffix
          ]),
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

  defp resolve_timing(raw) do
    start_val = raw[:dtstart] || raw[:start_time]
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

  # Local wall-clock time, deliberately not UTC. `_occ_start` has already been
  # shifted into the event's own zone, so a `Z` here would label a local time as
  # UTC. The wall clock is also the more stable of the two: it does not move
  # across a DST transition, so an occurrence keeps one identity all year and
  # the cache updates its row instead of growing a second one. Rows are keyed on
  # `(calendar_integration_id, uid)`, so changing this format changes identity
  # for every occurrence already cached and needs a migration to rewrite them,
  # in `event_colour_overrides.provider_uid` as well as in the cache itself.
  # `20260904094944_strip_utc_label_from_occurrence_uids` is the one that
  # accompanied the last such change, and the pattern to follow.
  defp occurrence_suffix(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")
  defp occurrence_suffix(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y%m%dT%H%M%S")
  defp occurrence_suffix(_other), do: "unknown"

  # `RECURRENCE-ID` reaches here as the raw property value: `20260501T100000`
  # when its TZID parameter named a zone (the event's own), `20260501T080000Z`
  # for a UTC instant, `20260501` for an all-day series. Each is reduced to the
  # same wall-clock stamp `occurrence_suffix/1` builds from an expanded
  # occurrence, so an override lines up with the occurrence it replaces
  # whichever of the three forms the server wrote.
  @recurrence_id ~r/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/

  defp recurrence_id_suffix(value, timezone) when is_binary(value) do
    case Regex.run(@recurrence_id, String.trim(value)) do
      [_all, y, m, d] -> y <> m <> d
      [_all, y, m, d, hh, mm, ss] -> "#{y}#{m}#{d}T#{hh}#{mm}#{ss}"
      [_all, y, m, d, hh, mm, ss, "Z"] -> utc_suffix_in_zone([y, m, d, hh, mm, ss], timezone)
      _unrecognised -> nil
    end
  end

  defp recurrence_id_suffix(_value, _timezone), do: nil

  defp utc_suffix_in_zone([y, m, d, hh, mm, ss], timezone) do
    with {:ok, date} <- Date.new(to_int(y), to_int(m), to_int(d)),
         {:ok, time} <- Time.new(to_int(hh), to_int(mm), to_int(ss)),
         {:ok, utc} <- DateTime.new(date, time, "Etc/UTC"),
         {:ok, local} <- to_event_zone(utc, timezone) do
      occurrence_suffix(local)
    else
      _unresolvable -> nil
    end
  end

  defp to_event_zone(datetime, timezone) when is_binary(timezone) and timezone != "",
    do: DateTime.shift_zone(datetime, timezone)

  defp to_event_zone(datetime, _no_zone), do: {:ok, datetime}

  defp to_int(value), do: String.to_integer(value)

  # --- Field mappers ---

  defp tymeslot_origin?(raw) do
    uid = raw[:uid] || ""
    String.ends_with?(uid, "@tymeslot.com")
  end

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

  defp map_attendee(a) when is_map(a) do
    %{
      email: MapKeys.get(a, :email),
      display_name: a["name"] || a["CN"] || a[:display_name],
      response_status: map_partstat(a["status"] || a["PARTSTAT"] || a[:response_status]),
      optional: false
    }
  end

  defp map_attendee(_other),
    do: %{email: nil, display_name: nil, response_status: nil, optional: false}

  defp map_partstat("accepted"), do: :accepted
  defp map_partstat("ACCEPTED"), do: :accepted
  defp map_partstat("declined"), do: :declined
  defp map_partstat("DECLINED"), do: :declined
  defp map_partstat("tentative"), do: :tentative
  defp map_partstat("TENTATIVE"), do: :tentative
  defp map_partstat("NEEDS-ACTION"), do: :needs_action
  defp map_partstat(_other), do: :needs_action

  defp map_reminders(nil), do: []
  defp map_reminders(alarms) when is_list(alarms), do: Enum.map(alarms, &map_alarm/1)
  defp map_reminders(alarm) when is_map(alarm), do: [map_alarm(alarm)]
  defp map_reminders(_other), do: []

  defp map_alarm(%{"trigger" => trigger}) when is_binary(trigger) do
    %{method: :popup, minutes_before: parse_trigger_minutes(trigger)}
  end

  defp map_alarm(%{trigger: trigger}) when is_binary(trigger) do
    %{method: :popup, minutes_before: parse_trigger_minutes(trigger)}
  end

  defp map_alarm(_other), do: %{method: :popup, minutes_before: 15}

  # Parses an iCal TRIGGER duration like "-PT15M" or "-PT1H" into minutes.
  defp parse_trigger_minutes(trigger) do
    stripped = String.replace(trigger, ~r/^-?PT?/, "")

    cond do
      String.contains?(stripped, "H") ->
        case Integer.parse(String.replace(stripped, ~r/H.*/, "")) do
          {h, _rest} -> h * 60
          :error -> 15
        end

      String.contains?(stripped, "M") ->
        case Integer.parse(String.replace(stripped, "M", "")) do
          {m, _rest} -> m
          :error -> 15
        end

      String.contains?(stripped, "S") ->
        case Integer.parse(String.replace(stripped, "S", "")) do
          {s, _rest} -> div(s, 60)
          :error -> 15
        end

      true ->
        15
    end
  end
end
