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

  defp convert_event(%CalendarEvent{all_day: true} = event, owner_timezone, target_timezone) do
    start_dt = DateTimeUtils.create_datetime_safe(event.start_date, ~T[00:00:00], owner_timezone)
    end_dt = DateTimeUtils.create_datetime_safe(event.end_date, ~T[00:00:00], owner_timezone)

    with {:ok, s} <- shift_safe(start_dt, target_timezone),
         {:ok, e} <- shift_safe(end_dt, target_timezone) do
      %{start_time: s, end_time: e}
    else
      _other -> nil
    end
  end

  defp convert_event(%CalendarEvent{all_day: false} = event, _owner_timezone, target_timezone) do
    with {:ok, s} <- shift_safe(event.start_at, target_timezone),
         {:ok, e} <- shift_safe(event.end_at, target_timezone) do
      %{start_time: s, end_time: e}
    else
      _other -> nil
    end
  end

  defp shift_safe(nil, _timezone), do: {:error, nil}

  defp shift_safe(%DateTime{} = dt, timezone) do
    if dt.time_zone == timezone do
      {:ok, dt}
    else
      DateTime.shift_zone(dt, timezone)
    end
  rescue
    _other -> {:error, :invalid_timezone}
  end
end
