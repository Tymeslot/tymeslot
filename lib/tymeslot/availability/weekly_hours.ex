defmodule Tymeslot.Availability.WeeklyHours do
  @moduledoc """
  A host's week as one shape: the days they take bookings and one window
  that applies to all of them, on their default schedule. Reached through
  `Tymeslot.Availability.weekly_hours/1` and `set_weekly_hours/2`.

  This is the simple week a first-run host chooses ("weekdays, 9 to 5"),
  not the per-day editor: writing it gives every chosen day the same hours
  and turns every other day off. Reading a week whose days differ gives the
  first available day's hours, so a later write would make them the same.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Repo
  alias Tymeslot.Utils.DateTimeUtils

  @all_days 1..7

  @typedoc """
  The week: ISO weekdays (1 is Monday) the host takes bookings on, and the
  window as `"HH:MM"`, ending the same day.
  """
  @type t :: %{days: [1..7], start: String.t(), end: String.t()}

  @type error :: :no_days | :end_before_start | :invalid_time | :no_schedule | term()

  @doc """
  The default schedule's week, or `nil` for a profile without a default
  schedule.
  """
  @spec get(integer()) :: t() | nil
  def get(profile_id) do
    case Schedules.get_default(profile_id) do
      nil -> nil
      schedule -> schedule.id |> WeeklySchedule.get_weekly_schedule() |> from_days()
    end
  end

  defp from_days(days) do
    open =
      days
      |> Enum.filter(&((&1.is_available and &1.start_time) && &1.end_time))
      |> Enum.sort_by(& &1.day_of_week)

    case open do
      [] ->
        %{days: [], start: "09:00", end: "17:00"}

      [first | _rest] ->
        %{
          days: Enum.map(open, & &1.day_of_week),
          start: hhmm(first.start_time),
          end: hhmm(first.end_time)
        }
    end
  end

  defp hhmm(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  @doc """
  Checks a week before it is written: at least one day, times that parse,
  and an end after the start.
  """
  @spec validate(map()) :: :ok | {:error, :no_days | :end_before_start | :invalid_time}
  def validate(%{days: days, start: start_str, end: end_str}) do
    with :ok <- validate_days(days),
         {:ok, start_time} <- parse(start_str),
         {:ok, end_time} <- parse(end_str) do
      if Time.compare(end_time, start_time) == :gt, do: :ok, else: {:error, :end_before_start}
    end
  end

  defp validate_days(days) when is_list(days) and days != [] do
    if Enum.all?(days, &(&1 in @all_days)), do: :ok, else: {:error, :no_days}
  end

  defp validate_days(_days), do: {:error, :no_days}

  defp parse(value) when is_binary(value) do
    case DateTimeUtils.parse_hhmm(value) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, :invalid_time}
    end
  end

  defp parse(_value), do: {:error, :invalid_time}

  @doc """
  Writes the week to the profile's default schedule in one transaction: the
  chosen days get the window, every other day is turned off. A refusal
  partway (a day whose breaks fall outside the new window) leaves the week
  as it was. The cached availability is cleared once it commits.
  """
  @spec set(integer(), map()) :: :ok | {:error, error()}
  def set(profile_id, %{days: days} = hours) do
    with :ok <- validate(hours),
         %{} = schedule <- Schedules.get_default(profile_id) || {:error, :no_schedule},
         {:ok, :ok} <- Repo.transaction(fn -> write(profile_id, schedule.id, days, hours) end) do
      Availability.changed(schedule)
    end
  end

  defp write(profile_id, schedule_id, days, hours) do
    Enum.each(@all_days, fn day ->
      result =
        if day in days,
          do:
            AvailabilityActions.update_day_hours(
              profile_id,
              schedule_id,
              day,
              hours.start,
              hours.end
            ),
          # Passing "currently available" turns the day off and clears it.
          else: AvailabilityActions.toggle_day_availability(profile_id, schedule_id, day, true)

      case result do
        {:ok, _day} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
