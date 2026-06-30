defmodule Tymeslot.Integrations.Calendar.VTimezone do
  @moduledoc """
  Parses embedded `VTIMEZONE` components (RFC 5545 §3.6.5) from raw iCalendar
  text and resolves naive local datetimes for the custom, non-IANA `TZID`s they
  define.

  Some calendar clients — notably Microsoft Outlook exporting to CalDAV — emit
  `TZID`s that no time zone database recognises (`Customized Time Zone`, a bare
  numeric `1`, …) and, as the RFC requires, bundle the offset rules inline as a
  `VTIMEZONE` component. The main datetime path
  (`Tymeslot.Utils.DateTimeUtils.ICal`) is consulted first; the iCal parser only
  falls back to this resolver when the configured time zone database cannot
  resolve a `TZID`, so genuine IANA zones always win.

  Supports the common Outlook/EU shape: a single `STANDARD` plus optional
  `DAYLIGHT` sub-component, each carrying a `TZOFFSETTO` and an `RRULE` of the
  form `FREQ=YEARLY;BYMONTH=m;BYDAY=[-]nDD`. The applicable offset is selected
  per the event's own year, so daylight-saving events resolve to the correct
  UTC instant rather than a single fixed offset. Sub-components without a usable
  recurrence rule collapse to their fixed `TZOFFSETTO`.
  """

  alias Tymeslot.Timezones

  @enforce_keys [:standard]
  defstruct [:standard, :daylight]

  @typep sub :: %{offset: integer(), transition: transition() | nil}
  @typep transition :: %{
           month: 1..12,
           ordinal: integer(),
           weekday: 1..7,
           time: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
         }

  @type t :: %__MODULE__{standard: sub(), daylight: sub() | nil}

  @weekdays %{"MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7}

  @doc """
  Extracts every `VTIMEZONE` component from raw iCalendar `content` into a map
  of sanitised `TZID` → `t()`. Components lacking a usable `STANDARD` offset are
  skipped. Keys are sanitised with `Timezones.sanitize/1` so lookups line up
  with the parser's already-sanitised `TZID` parameter values.
  """
  @spec parse(binary()) :: %{optional(String.t()) => t()}
  def parse(content) when is_binary(content) do
    ~r/BEGIN:VTIMEZONE\r?\n(.*?)\r?\nEND:VTIMEZONE/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_match, body] -> parse_block(body) end)
    |> Map.new()
  end

  @doc """
  Converts a naive local datetime to UTC using the offset in effect on that
  datetime's own date. Returns `{:ok, DateTime.t()}`.
  """
  @spec to_utc(t(), NaiveDateTime.t()) :: {:ok, DateTime.t()}
  def to_utc(%__MODULE__{} = vtz, %NaiveDateTime{} = naive) do
    offset = offset_seconds(vtz, naive)

    naive
    |> NaiveDateTime.add(-offset, :second)
    |> DateTime.from_naive("Etc/UTC")
  end

  # --- offset resolution -----------------------------------------------------

  defp offset_seconds(%__MODULE__{standard: standard, daylight: nil}, _naive), do: standard.offset

  defp offset_seconds(%__MODULE__{standard: standard, daylight: daylight}, naive) do
    with %{transition: %{} = dst_rule} <- daylight,
         %{transition: %{} = std_rule} <- standard,
         %NaiveDateTime{} = dst_start <- onset(dst_rule, naive.year),
         %NaiveDateTime{} = std_start <- onset(std_rule, naive.year) do
      if in_daylight?(naive, dst_start, std_start), do: daylight.offset, else: standard.offset
    else
      _missing_rule -> standard.offset
    end
  end

  defp in_daylight?(naive, dst_start, std_start) do
    if NaiveDateTime.compare(dst_start, std_start) == :lt do
      # Northern hemisphere: DST runs from spring (dst_start) to autumn (std_start)
      after_or_eq?(naive, dst_start) and before?(naive, std_start)
    else
      # Southern hemisphere: the DST window wraps across the new year
      after_or_eq?(naive, dst_start) or before?(naive, std_start)
    end
  end

  defp after_or_eq?(a, b), do: NaiveDateTime.compare(a, b) != :lt
  defp before?(a, b), do: NaiveDateTime.compare(a, b) == :lt

  defp onset(%{month: month, ordinal: ordinal, weekday: weekday, time: {h, m, s}}, year) do
    with {:ok, date} <- nth_weekday_date(year, month, weekday, ordinal),
         {:ok, time} <- Time.new(h, m, s),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      naive
    else
      _invalid -> nil
    end
  end

  defp nth_weekday_date(year, month, weekday, -1) do
    with {:ok, first} <- Date.new(year, month, 1) do
      last_day = Date.days_in_month(first)
      {:ok, last} = Date.new(year, month, last_day)
      offset = Integer.mod(Date.day_of_week(last) - weekday, 7)
      Date.new(year, month, last_day - offset)
    end
  end

  defp nth_weekday_date(year, month, weekday, ordinal) when ordinal >= 1 do
    with {:ok, first} <- Date.new(year, month, 1) do
      offset = Integer.mod(weekday - Date.day_of_week(first), 7)
      Date.new(year, month, 1 + offset + (ordinal - 1) * 7)
    end
  end

  defp nth_weekday_date(_year, _month, _weekday, _ordinal), do: :error

  # --- block parsing ---------------------------------------------------------

  defp parse_block(body) do
    with tzid when is_binary(tzid) <- extract_tzid(body),
         %{} = standard <- parse_sub(body, "STANDARD") do
      [{tzid, %__MODULE__{standard: standard, daylight: parse_sub(body, "DAYLIGHT")}}]
    else
      _unusable -> []
    end
  end

  defp extract_tzid(body) do
    case Regex.run(~r/^TZID:(.+?)\r?$/m, body) do
      [_match, raw] -> Timezones.sanitize(raw)
      _none -> nil
    end
  end

  defp parse_sub(body, kind) do
    with [_match, sub] <- Regex.run(~r/BEGIN:#{kind}\r?\n(.*?)\r?\nEND:#{kind}/s, body),
         offset when is_integer(offset) <- parse_offset(sub) do
      %{offset: offset, transition: parse_transition(sub)}
    else
      _missing -> nil
    end
  end

  defp parse_offset(sub) do
    case Regex.run(~r/^TZOFFSETTO:([+-])(\d{2})(\d{2})(\d{2})?\r?$/m, sub) do
      [_match, sign, hh, mm | rest] ->
        seconds =
          String.to_integer(hh) * 3600 + String.to_integer(mm) * 60 + trailing_seconds(rest)

        if sign == "-", do: -seconds, else: seconds

      _none ->
        nil
    end
  end

  defp trailing_seconds([ss]) when ss != "", do: String.to_integer(ss)
  defp trailing_seconds(_none), do: 0

  defp parse_transition(sub) do
    with [_match, rrule] <- Regex.run(~r/^RRULE:(.+?)\r?$/m, sub),
         params = parse_rrule(rrule),
         {:ok, month} <- fetch_int(params, "BYMONTH"),
         {ordinal, weekday} when is_integer(weekday) <- parse_byday(params["BYDAY"]) do
      %{month: month, ordinal: ordinal, weekday: weekday, time: dtstart_time(sub)}
    else
      _no_rule -> nil
    end
  end

  defp parse_rrule(rrule) do
    rrule
    |> String.split(";")
    |> Map.new(fn part ->
      case String.split(part, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  defp fetch_int(params, key) do
    with value when is_binary(value) <- Map.get(params, key),
         {int, _rest} <- Integer.parse(value) do
      {:ok, int}
    else
      _invalid -> :error
    end
  end

  defp parse_byday(nil), do: :error

  defp parse_byday(byday) do
    case Regex.run(~r/^(-?\d+)(MO|TU|WE|TH|FR|SA|SU)$/, byday) do
      [_match, ordinal, weekday] -> {String.to_integer(ordinal), @weekdays[weekday]}
      _none -> :error
    end
  end

  defp dtstart_time(sub) do
    case Regex.run(~r/^DTSTART:\d{8}T(\d{2})(\d{2})(\d{2})/m, sub) do
      [_match, h, m, s] -> {String.to_integer(h), String.to_integer(m), String.to_integer(s)}
      _none -> {0, 0, 0}
    end
  end
end
