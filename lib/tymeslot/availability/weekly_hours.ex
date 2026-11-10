defmodule Tymeslot.Availability.WeeklyHours do
  @moduledoc """
  A host's week as one shape: the days they take bookings and one window
  that applies to all of them, on their default schedule. Reached through
  `Tymeslot.Availability.weekly_hours/1` and `set_weekly_hours/2`.

  This is the simple week a first-run host chooses ("weekdays, 9 to 5"),
  not the per-day editor: writing it gives every chosen day the same hours
  and turns every other day off. Reading a week whose days differ gives the
  first available day's hours with `uniform: false`, so a caller can say the
  week is the host's own rather than pass it off as a preset.

  A write changes what the host offers but not their calendar, so it keeps
  the cached calendar events (`Availability.offer_changed/1`): the next
  read of the week folds the new hours over the same events, with no
  provider round trip.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Repo
  alias Tymeslot.Utils.DateTimeUtils

  @all_days 1..7

  @typedoc """
  The week: ISO weekdays (1 is Monday) the host takes bookings on, and the
  window as `"HH:MM"`, ending the same day. `uniform` (on a read) is whether
  every open day has that same window.
  """
  @type t :: %{
          required(:days) => [1..7],
          required(:start) => String.t(),
          required(:end) => String.t(),
          optional(:uniform) => boolean()
        }

  @type error ::
          :no_days
          | :invalid_day
          | :end_before_start
          | :invalid_time
          | :no_schedule
          | {:breaks_outside_hours, [map()]}
          | term()

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
      |> Enum.filter(&(&1.is_available && &1.start_time && &1.end_time))
      |> Enum.sort_by(& &1.day_of_week)

    case open do
      [] ->
        %{days: [], start: "09:00", end: "17:00", uniform: true}

      [first | _rest] ->
        %{
          days: Enum.map(open, & &1.day_of_week),
          start: hhmm(first.start_time),
          end: hhmm(first.end_time),
          uniform:
            Enum.all?(open, fn day ->
              day.start_time == first.start_time and day.end_time == first.end_time and
                not day.ends_next_day
            end)
        }
    end
  end

  defp hhmm(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  @doc """
  Checks a week before it is written: at least one day, every day an ISO
  weekday, times that parse, and an end after the start.
  """
  @spec validate(map()) ::
          :ok | {:error, :no_days | :invalid_day | :end_before_start | :invalid_time}
  def validate(%{days: days, start: start_str, end: end_str}) do
    with :ok <- validate_days(days),
         {:ok, start_time} <- parse(start_str),
         {:ok, end_time} <- parse(end_str) do
      if Time.compare(end_time, start_time) == :gt, do: :ok, else: {:error, :end_before_start}
    end
  end

  defp validate_days([_day | _rest] = days) do
    if Enum.all?(days, &(&1 in @all_days)), do: :ok, else: {:error, :invalid_day}
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
  chosen days get the window, every other day is turned off and its breaks
  cleared. A refusal partway (a day whose breaks fall outside the new
  window) leaves the week as it was. The cached availability ranges are
  cleared once, after it commits.
  """
  @spec set(integer(), map()) :: :ok | {:error, error()}
  def set(profile_id, %{days: days} = hours) do
    # The default schedule is read through the profile, which is the one
    # ownership check every day below relies on.
    with :ok <- validate(hours),
         %{} = schedule <- Schedules.get_default(profile_id) || {:error, :no_schedule},
         {:ok, window} <- window(hours),
         {:ok, :ok} <- Repo.transaction(fn -> write(schedule.id, days, window) end) do
      Availability.offer_changed(schedule)
    end
  end

  defp window(%{start: start_str, end: end_str}) do
    with {:ok, start_time} <- parse(start_str),
         {:ok, end_time} <- parse(end_str) do
      {:ok, %{start_time: start_time, end_time: end_time, ends_next_day: false}}
    end
  end

  defp write(schedule_id, days, window) do
    Enum.each(@all_days, fn day ->
      result =
        if day in days,
          do: open_day(schedule_id, day, window),
          else: WeeklySchedule.clear_day_settings(schedule_id, day)

      case result do
        {:ok, _day} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Narrowing a day past one of its breaks is refused, naming the breaks,
  # as the per-day editor refuses it: removing them would delete what the
  # host entered without asking.
  defp open_day(schedule_id, day, window) do
    breaks =
      case WeeklySchedule.get_day_availability(schedule_id, day) do
        %{breaks: breaks} when is_list(breaks) -> breaks
        _no_day -> []
      end

    case Breaks.outside_hours(breaks, window) do
      [] ->
        WeeklySchedule.upsert_day_availability(
          schedule_id,
          day,
          Map.put(window, :is_available, true)
        )

      stranded ->
        {:error, {:breaks_outside_hours, stranded}}
    end
  end
end
