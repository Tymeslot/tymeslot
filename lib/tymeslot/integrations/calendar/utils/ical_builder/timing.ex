defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Timing do
  @moduledoc """
  Writing a date or date-time property in the form of a series' `DTSTART`.

  Every member of a recurring event stored as one CalDAV resource names its
  timing the way the master's `DTSTART` does: an `EXDATE` and a
  `RECURRENCE-ID` only match a slot in that value type and zone (RFC 5545
  §3.8.5.1, §3.8.4.4), and an override's own `DTSTART` belongs in the same
  form so the series reads the same in every client. `Properties.build_dtstart/1`
  writes UTC, which is right for an event Tymeslot authors and wrong inside a
  zoned series: a UTC override of a Berlin series is a different wall clock
  on either side of a DST change for every client that shows it in the
  series' zone.

  The reference line is the master's `DTSTART` as the server wrote it; its
  parameters are copied as written. Its form is one of:

    * `VALUE=DATE` (or an eight-digit value): a date, `YYYYMMDD`.
    * A value ending in `Z`: a UTC instant, `YYYYMMDDTHHMMSSZ`.
    * A `TZID` parameter: the wall clock in that zone, `YYYYMMDDTHHMMSS`.
    * Neither: a floating wall clock, `YYYYMMDDTHHMMSS`.

  The zone a wall clock is read in is the series' IANA zone as the sync
  resolved it, since a `TZID` may name a zone only its own `VTIMEZONE`
  defines (`W. Europe Standard Time`); the parameter itself is used only when
  no zone was resolved. A floating series without one is read in UTC, as the
  sync reads it.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format

  @doc """
  Whether `reference`, a `DTSTART` line, names a date rather than a
  date-time.
  """
  @spec date?(String.t()) :: boolean()
  def date?(reference) do
    {name_and_params, value} = ContentLines.split_value(reference)

    Enum.any?(params(name_and_params), &(String.upcase(&1) == "VALUE=DATE")) or
      Regex.match?(~r/^\d{8}$/, String.trim(value))
  end

  @doc """
  The property `name` with `value` (a `Date` or a UTC `DateTime`) written in
  the form of `reference`. `timezone` is the series' IANA zone, or `nil`.

  Returns `{:error, :value_type_change}` when `value` is a date and the
  reference a date-time, or the reverse, and `{:error, :unknown_timezone}`
  when the wall clock cannot be placed in any zone.
  """
  @spec line(String.t(), Date.t() | DateTime.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :value_type_change | :unknown_timezone}
  def line(name, value, reference, timezone) do
    {name_and_params, reference_value} = ContentLines.split_value(reference)
    params = params(name_and_params)

    with {:ok, stamp} <- stamp(value, form(reference, params, reference_value), timezone) do
      {:ok, Enum.join([name | params], ";") <> ":" <> stamp}
    end
  end

  @doc """
  A `Date` end boundary as a date property's value demands it: exclusive,
  and at least a day after `start` (RFC 5545 §3.6.1), as
  `Properties.build_dtend/1` writes it for a new event.
  """
  @spec exclusive_end(Date.t(), Date.t()) :: Date.t()
  def exclusive_end(%Date{} = end_date, %Date{} = start) do
    if Date.compare(end_date, start) == :gt, do: end_date, else: Date.add(start, 1)
  end

  defp form(reference, params, value) do
    cond do
      date?(reference) -> :date
      String.ends_with?(String.trim(value), ["Z", "z"]) -> :utc
      tzid = Enum.find_value(params, &tzid/1) -> {:zoned, tzid}
      true -> :floating
    end
  end

  defp stamp(%Date{} = date, :date, _timezone), do: {:ok, Format.format_date(date)}
  defp stamp(%Date{}, _datetime_form, _timezone), do: {:error, :value_type_change}
  defp stamp(%DateTime{}, :date, _timezone), do: {:error, :value_type_change}

  defp stamp(%DateTime{} = datetime, :utc, _timezone),
    do: {:ok, Format.format_datetime(DateTime.shift_zone!(datetime, "Etc/UTC"))}

  defp stamp(%DateTime{} = datetime, {:zoned, tzid}, timezone),
    do: wall_clock(datetime, zone(timezone) || tzid)

  defp stamp(%DateTime{} = datetime, :floating, timezone),
    do: wall_clock(datetime, zone(timezone) || "Etc/UTC")

  defp wall_clock(datetime, zone) do
    case DateTime.shift_zone(datetime, zone) do
      {:ok, local} -> {:ok, local |> DateTime.to_naive() |> Format.format_naive_datetime()}
      {:error, _reason} -> {:error, :unknown_timezone}
    end
  end

  defp zone(timezone) when is_binary(timezone) and timezone != "", do: timezone
  defp zone(_none), do: nil

  defp params(name_and_params),
    do: name_and_params |> String.split(";") |> tl()

  defp tzid(param) do
    case String.split(param, "=", parts: 2) do
      [key, value] -> if String.upcase(key) == "TZID", do: String.trim(value, "\"")
      _other -> nil
    end
  end
end
