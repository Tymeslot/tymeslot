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

  @provider_labels %{caldav: "CalDAV", ics_url: "calendar subscription"}

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

    events =
      raw_events
      |> Enum.flat_map(&expand_event(&1, range_start, range_end))
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
    Logger.warning("Skipping invalid #{provider_label(provider)} calendar event",
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

  defp provider_label(provider), do: Map.get(@provider_labels, provider, "calendar")

  # ---------------------------------------------------------------------------
  # Recurrence expansion
  # ---------------------------------------------------------------------------

  defp expand_event(raw, range_start, range_end) do
    rrule = raw[:rrule] || raw[:recurrence_rule]

    if rrule && rrule != "" do
      timezone = raw[:timezone]

      expander_event = %{
        start_time: in_event_zone(raw[:dtstart] || raw[:start_time], timezone),
        end_time: in_event_zone(raw[:dtend] || raw[:end_time], timezone),
        recurrence_rule: rrule
      }

      exdates = parse_exdates(raw[:exdate] || raw[:exdates] || [])

      expander_event
      |> RecurrenceExpander.expand(range_start, range_end, exdates: exdates)
      |> Enum.map(fn occurrence ->
        raw
        |> Map.put(:_occ_start, occurrence.start_time)
        |> Map.put(:_occ_end, occurrence.end_time)
        |> Map.put(:_recurring, true)
      end)
    else
      [raw]
    end
  end

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
        provider_calendar_id: context.provider_calendar_id,
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
        provider_metadata: Map.drop(raw, [:raw_ical, :href, :_occ_start, :_occ_end, :_recurring]),
        raw_ical: raw[:raw_ical],
        created_by_tymeslot: tymeslot_origin?(raw)
      }
      |> Map.merge(timing_fields(all_day, start_val, end_val))
      |> maybe_put_timezone(timezone)

    CalendarEvent.new(attrs)
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
      is_struct(start_val, Date) and not is_struct(start_val, DateTime) ->
        # RFC 5545 §3.8.2.2: when DTEND is absent for a DATE-valued event,
        # it defaults to DTSTART + P1D (one day later).
        effective_end = end_val || Date.add(start_val, 1)
        {true, start_val, effective_end, nil}

      radicale_all_day?(start_val, end_val) ->
        {true, DateTime.to_date(start_val), DateTime.to_date(end_val), nil}

      is_struct(start_val, DateTime) ->
        tz = start_val.time_zone
        {false, DateTime.shift_zone!(start_val, "Etc/UTC"), shift_end(end_val), tz}

      true ->
        {false, start_val, end_val, nil}
    end
  end

  defp shift_end(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
  defp shift_end(other), do: other

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

  defp build_uid(%{_recurring: true} = raw) do
    base_uid = raw[:uid]
    occ_start = raw[:_occ_start]

    suffix =
      case occ_start do
        %Date{} = d ->
          Calendar.strftime(d, "%Y%m%d")

        %DateTime{} = dt ->
          Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")

        _other ->
          "unknown"
      end

    "#{base_uid}_#{suffix}"
  end

  defp build_uid(raw), do: raw[:uid]

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
