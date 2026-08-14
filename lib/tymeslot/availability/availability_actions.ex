defmodule Tymeslot.Availability.AvailabilityActions do
  @moduledoc """
  Handles availability-related business logic operations.
  This module provides a clean interface for availability operations
  without any UI-specific concerns.
  """

  alias Tymeslot.Availability.{Breaks, WeeklyAvailabilityQueries, WeeklySchedule}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.DateTimeUtils

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

    result =
      if new_available do
        WeeklySchedule.upsert_day_availability(profile_id, day, %{
          is_available: true,
          start_time: ~T[11:00:00],
          end_time: ~T[19:30:00]
        })
      else
        WeeklySchedule.clear_day_settings(profile_id, day)
      end

    with_cache_invalidation(result, profile_id)
  end

  @doc """
  Updates the working hours for a specific day.
  """
  @spec update_day_hours(integer(), integer(), String.t(), String.t()) ::
          {:ok, term()} | {:error, :invalid_time_format | Ecto.Changeset.t()}
  def update_day_hours(profile_id, day, start_str, end_str) do
    result =
      with {:ok, start_time} <- DateTimeUtils.parse_hhmm(start_str),
           {:ok, end_time} <- DateTimeUtils.parse_hhmm(end_str) do
        WeeklySchedule.upsert_day_availability(profile_id, day, %{
          is_available: true,
          start_time: start_time,
          end_time: end_time
        })
      else
        _error -> {:error, :invalid_time_format}
      end

    with_cache_invalidation(result, profile_id)
  end

  # Break Management Actions

  @doc """
  Adds a break to a day's availability.
  """
  @spec add_break(integer(), String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, :invalid_time_format | Ecto.Changeset.t()}
  def add_break(day_availability_id, start_str, end_str, label) do
    result =
      with {:ok, start_time} <- DateTimeUtils.parse_hhmm(start_str),
           {:ok, end_time} <- DateTimeUtils.parse_hhmm(end_str) do
        Breaks.add_break(
          day_availability_id,
          start_time,
          end_time,
          if(label == "", do: nil, else: label)
        )
      else
        _error -> {:error, :invalid_time_format}
      end

    with_cache_invalidation_by_availability(result, day_availability_id)
  end

  @doc """
  Adds a quick break with a predefined duration.
  """
  @spec add_quick_break(integer(), String.t(), integer()) ::
          {:ok, term()} | {:error, :invalid_time_format | Ecto.Changeset.t() | String.t()}
  def add_quick_break(day_availability_id, start_str, duration) do
    result =
      case DateTimeUtils.parse_hhmm(start_str) do
        {:ok, start_time} ->
          Breaks.add_quick_break(day_availability_id, start_time, duration)

        _error ->
          {:error, :invalid_time_format}
      end

    with_cache_invalidation_by_availability(result, day_availability_id)
  end

  @doc """
  Deletes a break, verifying that it belongs to the given profile.

  Returns `{:error, "Unauthorized"}` if the break belongs to a different profile.
  """
  @spec delete_break(integer(), integer()) :: {:ok, term()} | {:error, String.t()}
  def delete_break(break_id, profile_id) do
    result = Breaks.delete_break(break_id, profile_id)
    with_cache_invalidation(result, profile_id)
  end

  # Bulk Operations

  @doc """
  Copies settings from one day to multiple other days.
  """
  @spec copy_day_settings(integer(), integer(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def copy_day_settings(profile_id, from_day, to_days) do
    result = WeeklySchedule.copy_day_settings(profile_id, from_day, to_days)
    with_cache_invalidation(result, profile_id)
  end

  @doc """
  Applies a preset schedule to specified days.
  """
  @spec apply_preset(integer(), String.t(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def apply_preset(profile_id, preset, days) do
    result = WeeklySchedule.set_preset_schedule(profile_id, preset, days)
    with_cache_invalidation(result, profile_id)
  end

  @doc """
  Clears all settings for a specific day (sets to unavailable and removes all breaks).
  """
  @spec clear_day_settings(integer(), integer()) :: {:ok, term()} | {:error, term()}
  def clear_day_settings(profile_id, day) do
    result = WeeklySchedule.clear_day_settings(profile_id, day)
    with_cache_invalidation(result, profile_id)
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
  def format_changeset_error(%Ecto.Changeset{errors: [{field, {message, _opts}} | _rest]}) do
    "#{humanize_field(field)}: #{message}"
  end

  def format_changeset_error(_changeset), do: "An error occurred"

  @doc """
  Gets the display name for a day of the week.
  """
  @spec day_name(integer()) :: String.t()
  def day_name(1), do: "Monday"
  def day_name(2), do: "Tuesday"
  def day_name(3), do: "Wednesday"
  def day_name(4), do: "Thursday"
  def day_name(5), do: "Friday"
  def day_name(6), do: "Saturday"
  def day_name(7), do: "Sunday"
  def day_name(_day), do: "Unknown"

  # Private Helper Functions

  defp humanize_field(:start_time), do: "Start time"
  defp humanize_field(:end_time), do: "End time"

  defp humanize_field(field),
    do: field |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp with_cache_invalidation({:ok, _data} = result, profile_id) do
    case ProfileQueries.get_profile(profile_id) do
      %{user_id: user_id} -> AvailabilityCache.invalidate_for_user(user_id)
      nil -> :ok
    end

    result
  end

  defp with_cache_invalidation(result, _profile_id), do: result

  defp with_cache_invalidation_by_availability({:ok, _data} = result, weekly_availability_id) do
    case WeeklyAvailabilityQueries.get_weekly_availability(weekly_availability_id) do
      %{profile_id: profile_id} -> with_cache_invalidation(result, profile_id)
      nil -> result
    end
  end

  defp with_cache_invalidation_by_availability(result, _weekly_availability_id), do: result
end
