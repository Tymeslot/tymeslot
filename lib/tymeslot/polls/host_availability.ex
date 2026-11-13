defmodule Tymeslot.Polls.HostAvailability do
  @moduledoc """
  When a poll's host is free, for the week the create form shows them while
  they choose candidate times.

  Two layers, both as UTC `{from, to}` intervals:

    * `busy`: events in the host's connected calendars that block bookings,
      and their time off, read the way the published free/busy feed reads
      them (`Tymeslot.FreeBusy.busy_intervals/3`, the event cache rather than
      a provider round trip, so paging through weeks stays quick);
    * `hours`: the open hours of their default schedule, breaks taken out,
      or nil for a host without a schedule, who then has no hours to be
      outside of.

  Like `Tymeslot.Polls.SlotHealth`, this is a hint only. A host may propose
  any time; confirmation is where a clash is enforced.
  """

  alias Tymeslot.Availability.{Intervals, Schedules, WeeklySchedule, Window}
  alias Tymeslot.FreeBusy
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  @type t :: %{busy: [Intervals.t()], hours: [Intervals.t()] | nil}
  @type status :: :free | :busy | :outside_hours

  @doc """
  `user_id`'s busy time and open hours between `window_start` and
  `window_end`. A user without a profile is free throughout.
  """
  @spec for_window(integer(), DateTime.t(), DateTime.t()) :: t()
  def for_window(user_id, %DateTime{} = window_start, %DateTime{} = window_end) do
    case Profiles.get_profile(user_id) do
      nil ->
        %{busy: [], hours: nil}

      profile ->
        bounds = {window_start, window_end}

        %{
          busy:
            profile
            |> FreeBusy.busy_intervals(window_start, window_end)
            |> Intervals.merge()
            |> Intervals.clip(bounds)
            |> Enum.map(&to_utc/1),
          hours: open_hours(profile, bounds)
        }
    end
  end

  @doc """
  How a meeting `minutes` long starting at `start_time` sits against
  `availability`: `:busy` when any of it overlaps busy time, `:outside_hours`
  when it is clear but not wholly inside the open hours, `:free` otherwise.
  The whole meeting is measured, not only its start, as `SlotHealth` does.
  """
  @spec status(t(), DateTime.t(), pos_integer()) :: status()
  def status(%{busy: busy, hours: hours}, %DateTime{} = start_time, minutes)
      when is_integer(minutes) and minutes > 0 do
    end_time = DateTime.add(start_time, minutes, :minute)

    cond do
      Enum.any?(busy, &overlaps?(&1, start_time, end_time)) -> :busy
      hours == nil or Intervals.covers?(hours, start_time, end_time) -> :free
      true -> :outside_hours
    end
  end

  defp overlaps?({from, to}, start_time, end_time),
    do: DateTime.before?(from, end_time) and DateTime.after?(to, start_time)

  defp open_hours(%ProfileSchema{} = profile, {window_start, window_end} = bounds) do
    case Schedules.get_default(profile.id) do
      nil ->
        nil

      schedule ->
        timezone = Profiles.timezone(profile)
        rows = Map.new(WeeklySchedule.get_weekly_schedule(schedule.id), &{&1.day_of_week, &1})

        # A day before the window: an overnight window opening then can
        # reach into it.
        first = window_start |> local_date(timezone) |> Date.add(-1)
        last = local_date(window_end, timezone)

        first
        |> Date.range(last)
        |> Enum.flat_map(&day_hours(Map.get(rows, Date.day_of_week(&1)), &1, timezone))
        |> Intervals.merge()
        |> Intervals.clip(bounds)
        |> Enum.map(&to_utc/1)
    end
  end

  defp day_hours(%{is_available: true, start_time: %Time{}, end_time: %Time{}} = row, date, tz) do
    breaks =
      Enum.map(row.breaks, &Window.resolve_break(row, {&1.start_time, &1.end_time}, date, tz))

    Intervals.subtract([Window.resolve(row, date, tz)], breaks)
  end

  defp day_hours(_closed_or_missing, _date, _timezone), do: []

  defp to_utc({from, to}), do: {utc(from), utc(to)}

  defp utc(datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

  defp local_date(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> DateTime.to_date(datetime)
    end
  end
end
