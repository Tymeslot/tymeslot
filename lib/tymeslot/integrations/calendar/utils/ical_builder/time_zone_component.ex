defmodule Tymeslot.Integrations.Calendar.ICalBuilder.TimeZoneComponent do
  @moduledoc """
  Writes the `VTIMEZONE` component (RFC 5545 §3.6.5) that a series written
  in a `TZID` needs beside it.

  Each offset change of the zone inside the span asked for becomes its own
  `STANDARD` or `DAYLIGHT` subcomponent with a `DTSTART`, `TZOFFSETFROM` and
  `TZOFFSETTO`, read from the time zone database. Explicit transitions need
  no `RRULE` in the component, so nothing about the zone's future rules has
  to be inferred, and every subcomponent carries what strict servers
  (Radicale's vobject among them) require: an earlier version that sent an
  incomplete `VTIMEZONE` was rejected with HTTP 400.

  The first subcomponent is the observance already in force when the span
  begins, starting at the change that brought it in; a zone that has not
  changed its offset in the year before gets one that starts on
  1 January 1970.

  ## Which events are written in a zone

  Only a timed series (`series_zone/1`): a single event and an all-day series
  do not move across a DST change, so they keep the UTC and DATE forms every
  server already accepts. The zone comes from the payload's
  `:series_timezone`, which only the CalDAV writers read; Google and Outlook
  read the same zone from `:timezone`.

  ## The span

  From the series' first start to its `UNTIL`, and never more than
  `@open_ended_years` (10) years on, which is also the span of a series
  without one (open-ended, or ended by `COUNT`). That bounds the component
  at about twenty subcomponents and the time to work it out. Past its last transition a
  reader that relies on the component alone keeps the last offset; clients
  and servers that know the IANA `TZID` (the mainstream ones) read the zone
  from their own database and are not limited by it.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  @open_ended_years 10

  # A zone that never leaves UTC gains nothing from a TZID.
  @utc_zones ~w(Etc/UTC UTC Etc/GMT GMT Etc/UCT UCT Etc/Zulu Zulu)

  # Offset changes are found by stepping through the span this far apart and
  # narrowing down to the second on a change. Zones change their offset at
  # most a few times a year, never twice within a week, so a change and its
  # reversal never fall between two steps. Each step costs a zone lookup, and
  # past the years the time zone database precomputes a lookup is slow: a
  # ten-year series stepped every twelve hours took a quarter of a second.
  @step_seconds 7 * 86_400

  # How far back to look for the change that brought in the observance in
  # force when the span begins.
  @lookback_days 366

  @epoch_observance ~N[1970-01-01 00:00:00]

  @doc """
  The zone `event`, a write payload, is written in: its `:series_timezone`
  when it is a timed event with a recurrence rule and the zone is one the
  time zone database knows and not UTC; `nil` otherwise, for the UTC form.
  """
  @spec series_zone(map()) :: String.t() | nil
  def series_zone(
        %{series_timezone: zone, recurrence_rule: rule, start_time: %DateTime{} = start} = event
      )
      when is_binary(zone) and is_binary(rule) and rule != "" do
    if Map.get(event, :all_day) != true and not utc_zone?(zone) and
         match?({:ok, _local}, DateTime.shift_zone(start, zone)),
       do: zone
  end

  def series_zone(_event), do: nil

  @doc """
  Whether `zone` is one of the names for UTC. An event synced from a
  document written in UTC carries such a zone, which says nothing about the
  local time its series was meant to keep.
  """
  @spec utc_zone?(String.t()) :: boolean()
  def utc_zone?(zone), do: zone in @utc_zones

  @doc """
  The `VTIMEZONE` lines for `event`'s series in `zone`, over the span the
  moduledoc describes.
  """
  @spec for_series(map(), String.t()) :: [String.t()] | nil
  def for_series(%{start_time: %DateTime{} = start, recurrence_rule: rule}, zone) do
    until =
      case RRule.parse(rule) do
        {:ok, parsed} -> RRule.until_instant(parsed, zone)
        :error -> nil
      end

    horizon = DateTime.shift(start, year: @open_ended_years)

    to =
      if until && DateTime.after?(until, start) && DateTime.before?(until, horizon),
        do: until,
        else: horizon

    lines(zone, start, to)
  end

  @doc """
  The `VTIMEZONE` lines for `zone` over `[from, to]`, or `nil` for a zone the
  time zone database does not know.
  """
  @spec lines(String.t(), DateTime.t(), DateTime.t()) :: [String.t()] | nil
  def lines(zone, %DateTime{} = from, %DateTime{} = to) do
    case DateTime.shift_zone(from, zone) do
      {:ok, _local} ->
        transitions = transitions(zone, DateTime.add(from, -@lookback_days, :day), to)
        {before, within} = Enum.split_with(transitions, &DateTime.before?(&1.at, from))

        ["BEGIN:VTIMEZONE", "TZID:#{zone}"] ++
          first_observance(zone, from, List.last(before)) ++
          Enum.flat_map(within, &subcomponent/1) ++ ["END:VTIMEZONE"]

      {:error, _reason} ->
        nil
    end
  end

  defp first_observance(_zone, _from, %{} = transition), do: subcomponent(transition)

  defp first_observance(zone, from, nil) do
    period = period(from, zone)

    subcomponent(%{wall: @epoch_observance, from: period, to: period})
  end

  defp subcomponent(%{wall: wall, from: from, to: to}) do
    kind = if daylight?(from, to), do: "DAYLIGHT", else: "STANDARD"

    [
      "BEGIN:#{kind}",
      "DTSTART:#{Format.format_naive_datetime(wall)}",
      "TZOFFSETFROM:#{offset(from)}",
      "TZOFFSETTO:#{offset(to)}",
      "TZNAME:#{to.zone_abbr}",
      "END:#{kind}"
    ]
  end

  # Summer time is the period the database adds a saving to, except in a
  # zone that marks its winter period with a negative saving instead
  # (Europe/Dublin), where it is the period after a negative one.
  defp daylight?(_from, %{std_offset: std_offset}) when std_offset > 0, do: true
  defp daylight?(%{std_offset: from_std}, %{std_offset: 0}) when from_std < 0, do: true
  defp daylight?(_from, _to), do: false

  # Every offset change in `[from, to]`, in order, each with the instant it
  # happens, the wall clock it happens at in the offset before it (the form
  # RFC 5545 gives an observance's DTSTART), and the periods either side.
  defp transitions(zone, from, to) do
    from
    |> Stream.iterate(&DateTime.add(&1, @step_seconds, :second))
    |> Stream.take_while(&DateTime.before?(&1, to))
    |> Stream.concat([to])
    |> Stream.map(&{&1, period(&1, zone)})
    |> Stream.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{earlier, before}, {later, after_}] ->
      if total(before) == total(after_) do
        []
      else
        at = first_instant_of(after_, earlier, later, zone)
        [%{at: at, wall: wall_clock(at, before), from: before, to: period(at, zone)}]
      end
    end)
  end

  # The first second in `(earlier, later]` already in `period`'s offset.
  defp first_instant_of(period, earlier, later, zone) do
    if DateTime.diff(later, earlier) <= 1 do
      later
    else
      middle = DateTime.add(earlier, div(DateTime.diff(later, earlier), 2), :second)

      if total(period(middle, zone)) == total(period),
        do: first_instant_of(period, earlier, middle, zone),
        else: first_instant_of(period, middle, later, zone)
    end
  end

  defp period(instant, zone) do
    local = DateTime.shift_zone!(instant, zone)
    %{utc_offset: local.utc_offset, std_offset: local.std_offset, zone_abbr: local.zone_abbr}
  end

  defp total(%{utc_offset: utc_offset, std_offset: std_offset}), do: utc_offset + std_offset

  defp wall_clock(instant, period) do
    instant
    |> DateTime.to_naive()
    |> NaiveDateTime.add(total(period), :second)
  end

  defp offset(period) do
    seconds = total(period)
    sign = if seconds < 0, do: "-", else: "+"
    absolute = abs(seconds)

    {hours, minutes, rest} =
      {div(absolute, 3600), div(rem(absolute, 3600), 60), rem(absolute, 60)}

    hhmm = sign <> pad(hours) <> pad(minutes)
    if rest == 0, do: hhmm, else: hhmm <> pad(rest)
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
