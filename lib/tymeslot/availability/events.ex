defmodule Tymeslot.Availability.Events do
  @moduledoc """
  Pure functions for event processing and timezone conversion.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @type calendar_event :: %{
          required(:start_time) => DateTime.t() | Date.t(),
          required(:end_time) => DateTime.t() | Date.t(),
          optional(:transparency) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Converts a list of events to a specific timezone.
  Handles both DateTime (normal) and Date (all-day) events.
  """
  @spec convert_events_to_timezone([calendar_event()], String.t(), String.t()) :: [
          calendar_event()
        ]
  def convert_events_to_timezone(events, owner_timezone, target_timezone) do
    events
    |> Enum.map(fn event ->
      # Convert start_time and end_time, anchoring Dates to owner's timezone first
      start_dt = ensure_datetime(event.start_time, owner_timezone)
      end_dt = ensure_datetime(event.end_time, owner_timezone)

      case {shift_safe(start_dt, target_timezone), shift_safe(end_dt, target_timezone)} do
        {{:ok, s}, {:ok, e}} ->
          %{event | start_time: s, end_time: e}

        _other ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ensure_datetime(%DateTime{} = dt, _timezone), do: dt

  defp ensure_datetime(%Date{} = d, timezone) do
    # All-day event: starts at 00:00:00 in the owner's timezone
    DateTimeUtils.create_datetime_safe(d, ~T[00:00:00], timezone)
  end

  defp ensure_datetime(nil, _timezone), do: nil
  defp ensure_datetime(_other, _timezone), do: nil

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
