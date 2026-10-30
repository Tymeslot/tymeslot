defmodule Tymeslot.Integrations.Calendar.ICalNormaliser.Expansion do
  @moduledoc """
  Recurrence expansion for `Tymeslot.Integrations.Calendar.ICalNormaliser`:
  turns a batch as `Tymeslot.Integrations.Calendar.ICalParser` emits it into
  one map per occurrence within a range, with each series expanded in its own
  zone and the occurrences its overrides replace left out.

  ## Marker contract

  `expand_all/3` adds these keys to the raw maps it returns, and
  `ICalNormaliser` reads them when it builds a `CalendarEvent`:

    * `_recurring` — `true` on an occurrence generated from a series' RRULE.
      Only such a map carries `_occ_start` and `_occ_end`.
    * `_occ_start`, `_occ_end` — the occurrence's own start and end, in the
      event's zone when timed, which replace the master's DTSTART/DTEND.
    * `_uid_suffix` — the occurrence's stamp, appended to the master's UID as
      `<uid>_<suffix>` to give each occurrence its own cache identity. Set on
      every generated occurrence and on every override (keyed by the slot its
      `RECURRENCE-ID` names); absent on a one-off event, which keeps its UID.

  The markers are internal: `marker_keys/0` lists them so a consumer can drop
  them before anything is stored or handed on.
  """

  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  @expansion_keys [:_occ_start, :_occ_end, :_recurring, :_uid_suffix]

  @doc "The marker keys `expand_all/3` may add to a raw event map."
  @spec marker_keys() :: [atom()]
  def marker_keys, do: @expansion_keys

  @doc """
  Expands `raw_events`, a batch as `ICalParser` emits it, into the events that
  occupy time within `[range_start, range_end]`, without building
  `CalendarEvent` structs: the shape the live busy-time check reads.

  A series is expanded exactly as `ICalNormaliser.normalise_events/3` expands
  it, in its own zone and with the occurrences its overrides replace left out,
  so the live check and the cache agree on when a recurring event takes place.
  Each occurrence keeps the master's fields with `start_time` and `end_time`
  set to its own times (in UTC when timed); overrides and one-off events pass
  through as they are.
  """
  @spec expand_occurrences([map()], DateTime.t(), DateTime.t()) :: [map()]
  def expand_occurrences(raw_events, range_start, range_end) do
    raw_events
    |> expand_all(range_start, range_end)
    |> Enum.map(&with_occurrence_times/1)
  end

  defp with_occurrence_times(%{_recurring: true} = raw) do
    raw
    |> Map.merge(%{start_time: in_utc(raw._occ_start), end_time: in_utc(raw._occ_end)})
    |> Map.drop(@expansion_keys)
  end

  defp with_occurrence_times(raw), do: Map.drop(raw, @expansion_keys)

  defp in_utc(%DateTime{} = datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")
  defp in_utc(value), do: value

  @doc """
  The one expansion of parser output, shared by
  `ICalNormaliser.normalise_events/3` and `expand_occurrences/3`: overrides are
  indexed against the whole batch before any master is expanded.

  Returns the raw maps with the markers described in the moduledoc added: each
  generated occurrence of a series carries `_recurring`, `_occ_start`,
  `_occ_end` and `_uid_suffix`; an override carries `_uid_suffix` only; a
  one-off event passes through unmarked.
  """
  @spec expand_all([map()], DateTime.t(), DateTime.t()) :: [map()]
  def expand_all(raw_events, range_start, range_end) do
    series_zones = index_series_zones(raw_events)
    overrides = index_overrides(raw_events, series_zones)

    Enum.flat_map(raw_events, &expand_event(&1, range_start, range_end, overrides, series_zones))
  end

  # A recurring event's CalDAV resource holds the master VEVENT plus one VEVENT
  # per occurrence that has been edited on its own, each carrying a
  # `RECURRENCE-ID` and no `RRULE`. They share the master's UID by RFC 5545, so
  # the pair `{uid, occurrence}` is what tells them apart. Indexed here once so
  # that expanding a master can skip the slots its overrides take over, rather
  # than generating an occurrence at the original time beside the edited one.
  defp index_overrides(raw_events, series_zones) do
    for raw <- raw_events,
        override?(raw),
        key = override_key(raw, series_zones),
        is_binary(key),
        into: MapSet.new(),
        do: {raw[:uid], key}
  end

  @doc """
  Whether `raw` is an override: a VEVENT carrying a `RECURRENCE-ID`, whatever
  else it carries.

  An override is never expanded: even one written with `RANGE=THISANDFUTURE`,
  which replaces its occurrence and every later one, is applied to its own slot
  only — the wider reading needs the master's rule truncated as well and is not
  attempted here.
  """
  @spec override?(map()) :: boolean()
  def override?(raw), do: is_binary(raw[:recurrence_id]) and raw[:recurrence_id] != ""

  # RFC 5545 §3.8.4.4 names an override's slot in the value type and zone of
  # the master's DTSTART, and the master's occurrences are keyed in that zone,
  # so a UTC `RECURRENCE-ID` is read in it too. The override's own DTSTART
  # zone is used only when the resource carries no master; another client may
  # have written the override's timing in UTC or in any other zone.
  defp index_series_zones(raw_events) do
    for raw <- raw_events,
        not override?(raw),
        rrule = raw[:rrule] || raw[:recurrence_rule],
        is_binary(rrule) and rrule != "",
        into: %{},
        do: {raw[:uid], raw[:timezone]}
  end

  defp override_key(raw, series_zones),
    do: occurrence_key(raw[:recurrence_id], Map.get(series_zones, raw[:uid], raw[:timezone]))

  defp expand_event(raw, range_start, range_end, overrides, series_zones) do
    rrule = raw[:rrule] || raw[:recurrence_rule]

    cond do
      override?(raw) ->
        # The override replaces the occurrence its `RECURRENCE-ID` names, so it
        # is identified by that slot and not by its own `DTSTART`: an override
        # that was itself rescheduled has a start that no longer matches the
        # occurrence it stands in for, and suffixing from it would file the row
        # beside that occurrence instead of over it. Its timing, summary and
        # the rest still come from its own properties.
        [Map.put(raw, :_uid_suffix, override_key(raw, series_zones) || own_suffix(raw))]

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
    rdates = parse_exdates(raw[:rdates] || [])

    expander_event
    |> RecurrenceExpander.expand(range_start, range_end, exdates: exdates, rdates: rdates)
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

  @doc """
  Puts `value` back in the event's own `timezone` when it is a `DateTime` and
  the zone resolves; returns it unchanged otherwise.
  """
  @spec in_event_zone(term(), String.t() | nil) :: term()
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
  def in_event_zone(%DateTime{} = datetime, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  def in_event_zone(value, _timezone), do: value

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

  # The UTC marker's group always takes part in a timed match, so a value
  # without one captures it as "" rather than leaving it out.
  @recurrence_id ~r/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/

  @doc """
  Reduces a raw `RECURRENCE-ID` value to the key the cache files the
  occurrence it names under: the wall-clock stamp in the series' own zone,
  `YYYYMMDDTHHMMSS` for a timed series or `YYYYMMDD` for an all-day one, the
  same stamp an expanded occurrence's uid is suffixed with.

  The value arrives as written on the wire: `20260501T100000` when its `TZID`
  parameter named a zone (the event's own) and taken as written, likewise
  `20260501` for an all-day series, and `20260501T080000Z` for a UTC instant,
  which is shifted into `timezone` (the series' IANA zone, or `nil` to keep it
  in UTC). Every reader of a `RECURRENCE-ID` goes through this one rule, so an
  override lines up with the occurrence it replaces whichever of the three
  forms the server wrote.

  Returns `nil` for a value it cannot read.
  """
  @spec occurrence_key(String.t() | nil, String.t() | nil) :: String.t() | nil
  def occurrence_key(value, timezone) when is_binary(value) do
    case Regex.run(@recurrence_id, String.trim(value)) do
      [_all, y, m, d] -> y <> m <> d
      [_all, y, m, d, hh, mm, ss, ""] -> "#{y}#{m}#{d}T#{hh}#{mm}#{ss}"
      [_all, y, m, d, hh, mm, ss, "Z"] -> utc_suffix_in_zone([y, m, d, hh, mm, ss], timezone)
      _unrecognised -> nil
    end
  end

  def occurrence_key(_value, _timezone), do: nil

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
end
