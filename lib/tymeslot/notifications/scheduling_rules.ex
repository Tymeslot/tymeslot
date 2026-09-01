defmodule Tymeslot.Notifications.SchedulingRules do
  @moduledoc """
  Determines reminder-email timing: whether a reminder is still worth
  scheduling given how far out the meeting is, and the exact instant it
  should fire. Reads the clock and the `:notifications` config; otherwise
  side-effect free.
  """

  @doc """
  Calculates the scheduled time for a reminder email.
  """
  @spec calculate_reminder_time(DateTime.t(), pos_integer(), String.t()) :: DateTime.t()
  def calculate_reminder_time(meeting_start_time, value, unit) do
    seconds = reminder_interval_seconds(value, unit)
    DateTime.add(meeting_start_time, -seconds, :second)
  end

  @doc """
  Determines if a reminder should be scheduled based on meeting timing.
  """
  @spec should_schedule_reminder?(DateTime.t(), pos_integer(), String.t()) :: boolean()
  def should_schedule_reminder?(meeting_start_time, value, unit) do
    reminder_time = calculate_reminder_time(meeting_start_time, value, unit)
    DateTime.compare(reminder_time, DateTime.utc_now()) == :gt
  end

  # Private functions

  defp reminder_minutes do
    Keyword.get(Application.get_env(:tymeslot, :notifications, []), :reminder_minutes, 30)
  end

  defp reminder_interval_seconds(value, unit) when is_integer(value) and value > 0 do
    multiplier =
      case unit do
        "minutes" -> 60
        "hours" -> 3600
        "days" -> 86_400
        _other -> 60
      end

    value * multiplier
  end

  defp reminder_interval_seconds(_value, _unit), do: reminder_minutes() * 60
end
