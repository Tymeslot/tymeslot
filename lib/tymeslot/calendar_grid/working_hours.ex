defmodule Tymeslot.CalendarGrid.WorkingHours do
  @moduledoc """
  The hours the calendar leaves unshaded on each weekday: the
  organiser's default availability schedule, as `[start, end]` minutes from
  midnight keyed by ISO weekday (1 is Monday), or `nil` for a day off.

  Breaks are not cut out: the shading says roughly when the organiser works,
  and the bookable-slot layer draws the exact bookable windows. A window that
  runs past midnight is unshaded to midnight only; its after-midnight part is
  not carried into the next day. An organiser with no schedule gets weekdays
  from 08:00 to 18:00.
  """

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule

  @type day_hours :: [non_neg_integer()] | nil
  @type t :: %{pos_integer() => day_hours()}

  @weekday [480, 1080]
  @fallback %{
    1 => @weekday,
    2 => @weekday,
    3 => @weekday,
    4 => @weekday,
    5 => @weekday,
    6 => nil,
    7 => nil
  }

  @doc "The hours used when the organiser has no default schedule."
  @spec fallback() :: t()
  def fallback, do: @fallback

  @doc "The working hours from `profile`'s default schedule, or `fallback/0`."
  @spec for_profile(map() | nil) :: t()
  def for_profile(%{id: profile_id}) when is_integer(profile_id) do
    with %{id: schedule_id} <- Schedules.get_default(profile_id),
         [_first | _rest] = rows <- WeeklySchedule.get_weekly_schedule(schedule_id) do
      from_rows(rows)
    else
      _none -> @fallback
    end
  end

  def for_profile(_profile), do: @fallback

  @doc "Weekly availability rows as working hours; days without a row are off."
  @spec from_rows([map()]) :: t()
  def from_rows(rows) do
    Enum.reduce(rows, Map.new(1..7, &{&1, nil}), fn row, acc ->
      Map.put(acc, row.day_of_week, hours(row))
    end)
  end

  defp hours(
         %{is_available: true, start_time: %Time{} = start_time, end_time: %Time{} = end_time} =
           row
       ) do
    start = minutes(start_time)
    finish = if Map.get(row, :ends_next_day, false), do: 1440, else: minutes(end_time)

    if finish > start, do: [start, finish]
  end

  defp hours(_row), do: nil

  defp minutes(%Time{hour: hour, minute: minute}), do: hour * 60 + minute
end
