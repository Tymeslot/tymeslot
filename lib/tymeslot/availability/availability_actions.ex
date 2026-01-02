defmodule Tymeslot.Availability.AvailabilityActions do
  @moduledoc """
  Handles availability-related business logic operations.
  This module provides a clean interface for availability operations
  without any UI-specific concerns.
  """

  alias Tymeslot.Availability.{Breaks, WeeklySchedule}

  # Schedule Management Actions

  @doc """
  Ensures a complete weekly schedule exists for a profile.
  Creates default unavailable days for any missing days.
  """
  @spec ensure_complete_schedule(list(), integer()) :: list()
  def ensure_complete_schedule(weekly_schedule, profile_id) do
    existing_days = MapSet.new(Enum.map(weekly_schedule, & &1.day_of_week))

    # Create any missing days as unavailable
    Enum.each(1..7, fn day ->
      unless day in existing_days do
        {:ok, _day_availability} =
          WeeklySchedule.create_day_availability(profile_id, day, %{is_available: false})
      end
    end)

    # Return fully preloaded schedule with breaks
    WeeklySchedule.get_weekly_schedule(profile_id)
  end

  @doc """
  Toggles availability for a specific day with default hours.
  """
  @spec toggle_day_availability(integer(), integer(), boolean()) ::
          {:ok, term()} | {:error, term()}
  def toggle_day_availability(profile_id, day, current_is_available) do
    new_available = !current_is_available

    if new_available do
      WeeklySchedule.upsert_day_availability(profile_id, day, %{
        is_available: true,
        start_time: ~T[11:00:00],
        end_time: ~T[19:30:00]
      })
    else
      WeeklySchedule.clear_day_settings(profile_id, day)
    end
  end

  @doc """
  Updates the working hours for a specific day.
  """
  @spec update_day_hours(integer(), integer(), String.t(), String.t()) ::
          {:ok, term()} | {:error, atom()}
  def update_day_hours(profile_id, day, start_str, end_str) do
    with {:ok, start_time} <- Time.from_iso8601(start_str <> ":00"),
         {:ok, end_time} <- Time.from_iso8601(end_str <> ":00") do
      WeeklySchedule.upsert_day_availability(profile_id, day, %{
        is_available: true,
        start_time: start_time,
        end_time: end_time
      })
    else
      _ -> {:error, :invalid_time_format}
    end
  end

  # Break Management Actions

  @doc """
  Adds a break to a day's availability.
  """
  @spec add_break(integer(), String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, atom()}
  def add_break(day_availability_id, start_str, end_str, label) do
    with {:ok, start_time} <- Time.from_iso8601(start_str <> ":00"),
         {:ok, end_time} <- Time.from_iso8601(end_str <> ":00") do
      Breaks.add_break(
        day_availability_id,
        start_time,
        end_time,
        if(label == "", do: nil, else: label)
      )
    else
      _ -> {:error, :invalid_time_format}
    end
  end

  @doc """
  Adds a quick break with a predefined duration.
  """
  @spec add_quick_break(integer(), String.t(), integer()) :: {:ok, term()} | {:error, atom()}
  def add_quick_break(day_availability_id, start_str, duration) do
    case Time.from_iso8601(start_str <> ":00") do
      {:ok, start_time} ->
        Breaks.add_quick_break(day_availability_id, start_time, duration)

      _ ->
        {:error, :invalid_time_format}
    end
  end

  @doc """
  Deletes a break.
  """
  @spec delete_break(integer()) :: {:ok, term()} | {:error, String.t()}
  def delete_break(break_id) do
    Breaks.delete_break(break_id)
  end

  # Bulk Operations

  @doc """
  Copies settings from one day to multiple other days.
  """
  @spec copy_day_settings(integer(), integer(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def copy_day_settings(profile_id, from_day, to_days) do
    WeeklySchedule.copy_day_settings(profile_id, from_day, to_days)
  end

  @doc """
  Applies a preset schedule to specified days.
  """
  @spec apply_preset(integer(), String.t(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def apply_preset(profile_id, preset, days) do
    WeeklySchedule.set_preset_schedule(profile_id, preset, days)
  end

  @doc """
  Clears all settings for a specific day (sets to unavailable and removes all breaks).
  """
  @spec clear_day_settings(integer(), integer()) :: {:ok, term()} | {:error, term()}
  def clear_day_settings(profile_id, day) do
    WeeklySchedule.clear_day_settings(profile_id, day)
  end

  # Helper Functions

  @doc """
  Finds a specific day's availability from the schedule.
  """
  @spec get_day_from_schedule(list(), integer()) :: term() | nil
  def get_day_from_schedule(schedule, day) do
    Enum.find(schedule, &(&1.day_of_week == day))
  end

  @doc """
  Formats a changeset error for display.
  """
  @spec format_changeset_error(Ecto.Changeset.t() | term()) :: String.t()
  def format_changeset_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}) do
    "#{humanize_field(field)}: #{message}"
  end

  def format_changeset_error(_), do: "An error occurred"

  @doc """
  Gets the display name for a day of the week.
  """
  @spec day_name(integer()) :: String.t()
  def day_name(1), do: "Monday"
  @spec day_name(integer()) :: String.t()
  def day_name(2), do: "Tuesday"
  @spec day_name(integer()) :: String.t()
  def day_name(3), do: "Wednesday"
  @spec day_name(integer()) :: String.t()
  def day_name(4), do: "Thursday"
  @spec day_name(integer()) :: String.t()
  def day_name(5), do: "Friday"
  @spec day_name(integer()) :: String.t()
  def day_name(6), do: "Saturday"
  @spec day_name(integer()) :: String.t()
  def day_name(7), do: "Sunday"

  # Private Helper Functions

  defp humanize_field(:start_time), do: "Start time"
  defp humanize_field(:end_time), do: "End time"

  defp humanize_field(field),
    do: field |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
