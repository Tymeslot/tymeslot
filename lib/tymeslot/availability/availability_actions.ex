defmodule Tymeslot.Availability.AvailabilityActions do
  @moduledoc """
  Handles availability-related business logic operations.
  This module provides a clean interface for availability operations
  without any UI-specific concerns.
  """

  alias Tymeslot.Availability.AvailabilityScheduleQueries
  alias Tymeslot.Availability.{Breaks, WeeklyAvailabilityQueries, WeeklySchedule}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.DateTimeUtils

  # Schedule Management Actions

  @doc """
  Ensures a complete weekly schedule exists for a schedule.
  Creates default unavailable days for any missing days.
  """
  @spec ensure_complete_schedule(list(), integer()) :: list()
  def ensure_complete_schedule(weekly_schedule, schedule_id) do
    existing_days = MapSet.new(Enum.map(weekly_schedule, & &1.day_of_week))

    # Create any missing days as unavailable
    Enum.each(1..7, fn day ->
      unless day in existing_days do
        {:ok, _day_availability} =
          WeeklySchedule.create_day_availability(schedule_id, day, %{is_available: false})
      end
    end)

    # Return fully preloaded schedule with breaks
    WeeklySchedule.get_weekly_schedule(schedule_id)
  end

  @doc """
  Toggles availability for a specific day with default hours.
  """
  @spec toggle_day_availability(integer(), integer(), boolean()) ::
          {:ok, term()} | {:error, term()}
  def toggle_day_availability(schedule_id, day, current_is_available) do
    new_available = !current_is_available

    with_cache_invalidation(schedule_id, fn ->
      if new_available do
        WeeklySchedule.upsert_day_availability(schedule_id, day, %{
          is_available: true,
          start_time: WeeklyAvailabilityQueries.default_start_time(),
          end_time: WeeklyAvailabilityQueries.default_end_time()
        })
      else
        WeeklySchedule.clear_day_settings(schedule_id, day)
      end
    end)
  end

  @doc """
  Updates the working hours for a specific day.
  """
  @spec update_day_hours(integer(), integer(), String.t(), String.t()) ::
          {:ok, term()} | {:error, :invalid_time_format | Ecto.Changeset.t()}
  def update_day_hours(schedule_id, day, start_str, end_str) do
    with_cache_invalidation(schedule_id, fn ->
      with {:ok, start_time} <- DateTimeUtils.parse_hhmm(start_str),
           {:ok, end_time} <- DateTimeUtils.parse_hhmm(end_str) do
        WeeklySchedule.upsert_day_availability(schedule_id, day, %{
          is_available: true,
          start_time: start_time,
          end_time: end_time
        })
      else
        _error -> {:error, :invalid_time_format}
      end
    end)
  end

  # Break Management Actions

  @doc """
  Adds a break to a day's availability.
  """
  @spec add_break(integer(), String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, :invalid_time_format | Ecto.Changeset.t()}
  def add_break(day_availability_id, start_str, end_str, label) do
    with_cache_invalidation_by_availability(day_availability_id, fn ->
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
    end)
  end

  @doc """
  Adds a quick break with a predefined duration.
  """
  @spec add_quick_break(integer(), String.t(), integer()) ::
          {:ok, term()} | {:error, :invalid_time_format | Ecto.Changeset.t() | String.t()}
  def add_quick_break(day_availability_id, start_str, duration) do
    with_cache_invalidation_by_availability(day_availability_id, fn ->
      case DateTimeUtils.parse_hhmm(start_str) do
        {:ok, start_time} ->
          Breaks.add_quick_break(day_availability_id, start_time, duration)

        _error ->
          {:error, :invalid_time_format}
      end
    end)
  end

  @doc """
  Deletes a break, verifying that it belongs to the given schedule.

  Returns `{:error, "Unauthorized"}` if the break belongs to a different schedule.
  """
  @spec delete_break(integer(), integer()) :: {:ok, term()} | {:error, String.t()}
  def delete_break(break_id, schedule_id) do
    with_cache_invalidation(schedule_id, fn -> Breaks.delete_break(break_id, schedule_id) end)
  end

  # Bulk Operations

  @doc """
  Copies settings from one day to multiple other days.
  """
  @spec copy_day_settings(integer(), integer(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def copy_day_settings(schedule_id, from_day, to_days) do
    with_cache_invalidation(schedule_id, fn ->
      WeeklySchedule.copy_day_settings(schedule_id, from_day, to_days)
    end)
  end

  @doc """
  Applies a preset schedule to specified days.
  """
  @spec apply_preset(integer(), String.t(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def apply_preset(schedule_id, preset, days) do
    with_cache_invalidation(schedule_id, fn ->
      WeeklySchedule.set_preset_schedule(schedule_id, preset, days)
    end)
  end

  @doc """
  Clears all settings for a specific day (sets to unavailable and removes all breaks).
  """
  @spec clear_day_settings(integer(), integer()) :: {:ok, term()} | {:error, term()}
  def clear_day_settings(schedule_id, day) do
    with_cache_invalidation(schedule_id, fn ->
      WeeklySchedule.clear_day_settings(schedule_id, day)
    end)
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

  defp with_cache_invalidation(schedule_id, fun) do
    result = fun.()
    invalidate_for_schedule(schedule_id)
    result
  end

  defp with_cache_invalidation_by_availability(weekly_availability_id, fun) do
    result = fun.()

    case WeeklyAvailabilityQueries.get_weekly_availability(weekly_availability_id) do
      %{schedule_id: schedule_id} -> invalidate_for_schedule(schedule_id)
      _other -> :ok
    end

    result
  end

  # The cache is keyed by user, so invalidation walks schedule -> profile -> user.
  # A missing link is a no-op: failing to invalidate must never fail the edit the
  # user just made.
  defp invalidate_for_schedule(schedule_id) do
    with %{profile_id: profile_id} <- AvailabilityScheduleQueries.get(schedule_id),
         %{user_id: user_id} <- ProfileQueries.get_profile(profile_id) do
      AvailabilityCache.invalidate_for_user(user_id)
    else
      _other -> :ok
    end
  end
end
