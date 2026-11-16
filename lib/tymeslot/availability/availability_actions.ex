defmodule Tymeslot.Availability.AvailabilityActions do
  @moduledoc """
  The weekly-hours editor's operations on a schedule, its days and their
  breaks.

  Every action takes the acting profile's id and reaches the schedule or day
  only through it: an id that belongs to another profile's schedule gives
  `{:error, :not_found}` and changes nothing, whatever the caller passed.

  A write that lands calls `Tymeslot.Availability.changed/1`; a refusal
  does not. `update_day_hours/6` and `restore_day/5` take `notify: false`
  for a caller writing inside its own transaction, which calls `changed/1`
  itself once that commits.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.AvailabilityScheduleQueries
  alias Tymeslot.Availability.{Breaks, WeeklyAvailabilityQueries, WeeklySchedule, Window}
  alias Tymeslot.Utils.DateTimeUtils

  # Schedule Management Actions

  @doc """
  Ensures a complete weekly schedule exists for a schedule.
  Creates default unavailable days for any missing days.
  """
  @spec ensure_complete_schedule(integer(), list(), integer()) :: list()
  def ensure_complete_schedule(profile_id, weekly_schedule, schedule_id) do
    case AvailabilityScheduleQueries.get_for_profile(schedule_id, profile_id) do
      nil ->
        []

      _schedule ->
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
  end

  @doc """
  Toggles availability for a specific day with default hours.
  """
  @spec toggle_day_availability(integer(), integer(), integer(), boolean()) ::
          {:ok, term()} | {:error, term()}
  def toggle_day_availability(profile_id, schedule_id, day, current_is_available) do
    new_available = !current_is_available

    with_owned_schedule(profile_id, schedule_id, fn ->
      if new_available do
        WeeklySchedule.upsert_day_availability(schedule_id, day, %{
          is_available: true,
          start_time: WeeklyAvailabilityQueries.default_start_time(),
          end_time: WeeklyAvailabilityQueries.default_end_time(),
          ends_next_day: false
        })
      else
        WeeklySchedule.clear_day_settings(schedule_id, day)
      end
    end)
  end

  @doc """
  Updates the working hours for a specific day. `end_str` is the editor's
  value: `"HH:MM"` ends the same day, `"HH:MM+1"` the next
  (`Tymeslot.Availability.Window.parse_end/1`).
  """
  @spec update_day_hours(integer(), integer(), integer(), String.t(), String.t(), keyword()) ::
          {:ok, term()}
          | {:error,
             :invalid_time_format
             | :not_found
             | {:breaks_outside_hours, [map()]}
             | Ecto.Changeset.t()}
  def update_day_hours(profile_id, schedule_id, day, start_str, end_str, opts \\ []) do
    with_owned_schedule(profile_id, schedule_id, opts, fn ->
      with {:ok, start_time} <- DateTimeUtils.parse_hhmm(start_str),
           {:ok, {end_time, ends_next_day}} <- Window.parse_end(end_str) do
        hours = %{start_time: start_time, end_time: end_time, ends_next_day: ends_next_day}

        with :ok <- breaks_fit(schedule_id, day, hours) do
          WeeklySchedule.upsert_day_availability(
            schedule_id,
            day,
            Map.put(hours, :is_available, true)
          )
        end
      else
        _error -> {:error, :invalid_time_format}
      end
    end)
  end

  # Narrowing a day's hours past one of its breaks is refused, naming the
  # breaks: removing them would delete what the host entered without asking.
  defp breaks_fit(schedule_id, day, hours) do
    breaks =
      case WeeklySchedule.get_day_availability(schedule_id, day) do
        %{breaks: breaks} when is_list(breaks) -> breaks
        _no_day -> []
      end

    case Breaks.outside_hours(breaks, hours) do
      [] -> :ok
      stranded -> {:error, {:breaks_outside_hours, stranded}}
    end
  end

  # Break Management Actions

  @doc """
  Adds a break to a day's availability.
  """
  @spec add_break(integer(), integer(), String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, :invalid_time_format | :not_found | Ecto.Changeset.t()}
  def add_break(profile_id, day_availability_id, start_str, end_str, label) do
    with_owned_day(profile_id, day_availability_id, fn ->
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
  @spec add_quick_break(integer(), integer(), String.t(), integer()) ::
          {:ok, term()}
          | {:error, :invalid_time_format | :not_found | Ecto.Changeset.t() | String.t()}
  def add_quick_break(profile_id, day_availability_id, start_str, duration) do
    with_owned_day(profile_id, day_availability_id, fn ->
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
  @spec delete_break(integer(), integer(), integer()) ::
          {:ok, term()} | {:error, String.t() | :not_found}
  def delete_break(profile_id, break_id, schedule_id) do
    with_owned_schedule(profile_id, schedule_id, fn ->
      Breaks.delete_break(break_id, schedule_id)
    end)
  end

  # Bulk Operations

  @doc """
  Copies settings from one day to multiple other days.
  """
  @spec copy_day_settings(integer(), integer(), integer(), list(integer())) ::
          {:ok, term()} | {:error, term()}
  def copy_day_settings(profile_id, schedule_id, from_day, to_days) do
    with_owned_schedule(profile_id, schedule_id, fn ->
      WeeklySchedule.copy_day_settings(schedule_id, from_day, to_days)
    end)
  end

  @doc """
  Writes a day's row exactly as given (`:is_available` and its hours),
  leaving its breaks alone. For putting a day back as it was. Refused, as
  `update_day_hours/6` is, when a break the day holds would fall outside
  those hours.
  """
  @spec restore_day(integer(), integer(), integer(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def restore_day(profile_id, schedule_id, day, attrs, opts \\ []) when is_map(attrs) do
    with_owned_schedule(profile_id, schedule_id, opts, fn ->
      with :ok <- breaks_fit(schedule_id, day, attrs) do
        WeeklySchedule.upsert_day_availability(schedule_id, day, attrs)
      end
    end)
  end

  @doc """
  Clears all settings for a specific day (sets to unavailable and removes all breaks).
  """
  @spec clear_day_settings(integer(), integer(), integer()) :: {:ok, term()} | {:error, term()}
  def clear_day_settings(profile_id, schedule_id, day) do
    with_owned_schedule(profile_id, schedule_id, fn ->
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

  # Private Helper Functions

  # Runs `fun` only for a schedule the profile owns, then refreshes that
  # schedule's booking pages if it wrote.
  defp with_owned_schedule(profile_id, schedule_id, opts \\ [], fun) do
    case AvailabilityScheduleQueries.get_for_profile(schedule_id, profile_id) do
      nil -> {:error, :not_found}
      schedule -> run_and_invalidate(schedule, fun, Keyword.get(opts, :notify, true))
    end
  end

  # As `with_owned_schedule/3`, for a day reached by its own id.
  defp with_owned_day(profile_id, weekly_availability_id, fun) do
    case WeeklyAvailabilityQueries.get_for_profile(weekly_availability_id, profile_id) do
      nil -> {:error, :not_found}
      day -> run_and_invalidate(AvailabilityScheduleQueries.get(day.schedule_id), fun, true)
    end
  end

  # A refusal wrote nothing, so there is nothing for anyone to recompute.
  defp run_and_invalidate(schedule, fun, notify?) do
    result = fun.()
    if notify? and not match?({:error, _reason}, result), do: Availability.changed(schedule)
    result
  end
end
