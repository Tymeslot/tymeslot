defmodule Tymeslot.Availability.Events do
  @moduledoc """
  Pure functions for event processing and timezone conversion.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  Converts a list of `CalendarEvent` structs to a specific timezone, returning
  lightweight maps with `start_time` / `end_time` (both `DateTime`) that
  downstream conflict-checking code can consume directly.

  - **All-day events** (`all_day: true`): dates are anchored to midnight in the
    owner's timezone, then shifted to the target timezone.
  - **Timed events** (`all_day: false`): `start_at` / `end_at` are shifted to
    the target timezone via `DateTime.shift_zone/2`.

  Events that cannot be converted (e.g. invalid timezone data) are dropped.
  """
  @spec convert_events_to_timezone([CalendarEvent.t()], String.t(), String.t()) :: [map()]
  def convert_events_to_timezone(events, owner_timezone, target_timezone) do
    events
    |> Enum.map(&convert_event(&1, owner_timezone, target_timezone))
    |> Enum.reject(&is_nil/1)
  end

  # Plain maps from the OAuth / CalDAV fresh-fetch path carry start_time/end_time
  # directly. Timed events have DateTime values; all-day events typically have
  # Date values (anchored to midnight in the owner's timezone before shifting).
  #
  # Some CalDAV servers (Radicale, Zimbra) emit all-day events as a pair of
  # VALUE=DATE-TIME DTSTART/DTEND values at UTC midnight rather than VALUE=DATE.
  # Treating those as genuine timed events would offset the 24h block by the
  # owner's UTC offset (e.g. 12h wrong for Pacific/Fiji). When the provider
  # explicitly sets `all_day: true` on the plain map, detect the pattern and
  # re-anchor to owner-local midnight instead. Events without `all_day: true`
  # (or with `all_day: false`) are passed through as timed events so that a
  # genuine 24-hour timed slot starting at UTC midnight is never mis-classified.
  defp convert_event(
         %{start_time: _start_time, end_time: _end_time} = event,
         owner_timezone,
         target_timezone
       )
       when not is_struct(event) do
    {start_val, end_val} = maybe_reanchor_utc_midnight(event)

    with {:ok, s} <- shift_safe(start_val, owner_timezone, target_timezone),
         {:ok, e} <- shift_safe(end_val, owner_timezone, target_timezone) do
      %{start_time: s, end_time: e}
    else
      _other -> nil
    end
  end

  defp convert_event(%CalendarEvent{all_day: true} = event, owner_timezone, target_timezone) do
    with {:ok, s} <- shift_safe(event.start_date, owner_timezone, target_timezone),
         {:ok, e} <- shift_safe(event.end_date, owner_timezone, target_timezone) do
      %{start_time: s, end_time: e}
    else
      _other -> nil
    end
  end

  defp convert_event(%CalendarEvent{all_day: false} = event, owner_timezone, target_timezone) do
    with {:ok, s} <- shift_safe(event.start_at, owner_timezone, target_timezone),
         {:ok, e} <- shift_safe(event.end_at, owner_timezone, target_timezone) do
      %{start_time: s, end_time: e}
    else
      _other -> nil
    end
  end

  defp shift_safe(nil, _owner_timezone, _target_timezone), do: {:error, nil}

  defp shift_safe(%DateTime{} = dt, _owner_timezone, target_timezone) do
    if dt.time_zone == target_timezone do
      {:ok, dt}
    else
      DateTime.shift_zone(dt, target_timezone)
    end
  rescue
    _other -> {:error, :invalid_timezone}
  end

  defp shift_safe(%Date{} = date, owner_timezone, target_timezone) do
    date
    |> DateTimeUtils.create_datetime_safe(~T[00:00:00], owner_timezone)
    |> shift_safe(owner_timezone, target_timezone)
  end

  # Recognises the Radicale/Zimbra all-day-as-UTC-midnight convention: a pair
  # of UTC DateTimes where both sides sit exactly on a whole-day boundary and
  # the span is an integer number of days. Re-anchoring is gated on the
  # provider having explicitly set `all_day: true` on the plain map — without
  # that flag a UTC-midnight pair is treated as a genuine timed event (e.g.
  # a 24-hour maintenance window scheduled from 00:00Z to 00:00Z next day).
  defp maybe_reanchor_utc_midnight(%{
         all_day: true,
         start_time: %DateTime{} = s,
         end_time: %DateTime{} = e
       }) do
    if utc_midnight?(s) and utc_midnight?(e) and DateTime.compare(e, s) == :gt do
      {DateTime.to_date(s), DateTime.to_date(e)}
    else
      {s, e}
    end
  end

  defp maybe_reanchor_utc_midnight(%{start_time: start_val, end_time: end_val}),
    do: {start_val, end_val}

  defp utc_midnight?(%DateTime{
         time_zone: "Etc/UTC",
         hour: 0,
         minute: 0,
         second: 0,
         microsecond: {0, _precision}
       }),
       do: true

  defp utc_midnight?(_other), do: false
end
