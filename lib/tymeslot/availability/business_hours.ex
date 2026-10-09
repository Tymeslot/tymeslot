defmodule Tymeslot.Availability.BusinessHours do
  @moduledoc """
  Pure functions for business hours calculations.
  Uses the weekly availability of a named availability schedule.

  Windows are read per owner date, in the owner's own timezone, and resolved
  to instants (`owner_windows/4`); time off is read as instants too
  (`time_off_intervals/4`). The booker's timezone is no longer this module's
  concern: which of those instants a booker's date offers is decided by
  `Tymeslot.Availability.SlotGrid`.
  """

  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Intervals
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Availability.TimeOffPeriodQueries
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Availability.Window
  alias Tymeslot.Utils.DateTimeUtils

  # Fallback business hours configuration (for backwards compatibility)
  @fallback_start_time ~T[11:00:00]
  @fallback_end_time ~T[19:30:00]
  # Monday to Friday
  @fallback_working_days 1..5

  @typedoc "Availability for a single day of the week from a weekly schedule entry."
  @type day_availability :: %{
          required(:is_available) => boolean(),
          required(:day_of_week) => non_neg_integer(),
          optional(:start_time) => Time.t() | nil,
          optional(:end_time) => Time.t() | nil,
          optional(:ends_next_day) => boolean(),
          optional(:breaks) => list(term())
        }

  @typedoc """
  One owner date's window as instants in the owner's zone, with its breaks
  resolved and clipped to it.
  """
  @type owner_window :: %{
          required(:date) => Date.t(),
          required(:start_dt) => DateTime.t(),
          required(:end_dt) => DateTime.t(),
          required(:breaks) => [Intervals.t()]
        }

  @doc """
  The windows in effect on each of `dates` (owner dates), as instants in
  `owner_timezone`. An override outranks the weekly pattern, as before; a day
  that is closed, names no hours, or holds hours that are not a valid window
  contributes nothing. Time off is not applied here; see
  `time_off_intervals/4`.

  Each window's weekly breaks are resolved against the weekly row they belong
  to and clipped to the window in effect, so a break left outside its hours
  never blocks a neighbouring day.
  """
  @spec owner_windows(
          Enumerable.t(),
          integer() | nil,
          String.t(),
          Calculate.availability_config()
        ) :: [owner_window()]
  def owner_windows(dates, schedule_id, owner_timezone, config) do
    Enum.flat_map(dates, fn date ->
      case opening(date, schedule_id, config) do
        %{} = window -> [resolve_window(date, window, schedule_id, owner_timezone, config)]
        _closed -> []
      end
    end)
  end

  @doc """
  Time off covering `dates`, as UTC intervals read on the owner's clock.

  Periods are profile-wide, so they block clock time whichever day's hours
  run into them, and they outrank any override: one schedule's `available`
  exception cannot reopen time the owner is away for.
  """
  @spec time_off_intervals(
          Date.Range.t(),
          integer() | nil,
          String.t(),
          Calculate.availability_config()
        ) :: [Intervals.t()]
  def time_off_intervals(_dates, nil, _owner_timezone, _config), do: []

  def time_off_intervals(dates, schedule_id, owner_timezone, config) do
    dates |> lookup_time_off(schedule_id, config) |> TimeOff.intervals(owner_timezone)
  end

  @doc """
  Checks if a given date is a business day within a schedule.

  The question asked is whether anything is left of the day, in the owner's
  zone, once time off is taken out of the hours that reach into it: that
  date's own window and the previous date's overnight tail. Part-day periods
  that between them cover the whole of it leave nothing to book, and a day
  offering nothing must not be drawn as one that does.

  Breaks deliberately do not count, as before: this is the cheap answer the
  calendar shows before the real slot map arrives.

  Accepts preloaded data via `config` to avoid per-date DB queries.
  """
  @spec business_day?(Date.t(), integer() | nil, Calculate.availability_config()) :: boolean()
  def business_day?(date, schedule_id, config \\ %{})

  def business_day?(date, nil, _config) do
    Date.day_of_week(date) in @fallback_working_days
  end

  def business_day?(date, schedule_id, config) do
    owner_timezone = Map.get(config, :owner_timezone, "Etc/UTC")
    dates = Date.range(Date.add(date, -1), date)

    day =
      {DateTimeUtils.create_datetime_safe(date, ~T[00:00:00], owner_timezone),
       DateTimeUtils.create_datetime_safe(Date.add(date, 1), ~T[00:00:00], owner_timezone)}

    dates
    |> owner_windows(schedule_id, owner_timezone, config)
    |> Enum.map(&{&1.start_dt, &1.end_dt})
    |> Intervals.subtract(time_off_intervals(dates, schedule_id, owner_timezone, config))
    |> Intervals.clip(day)
    |> Kernel.!=([])
  end

  @typedoc """
  What the schedule alone says about a date, before time off is taken out of
  it: the window it opens in the owner's own clock, `:closed`, or `:no_hours`
  for a day marked available that names no window to offer.
  """
  @type day_opening :: Window.t() | :closed | :no_hours

  defp opening(date, nil, _config) do
    if Date.day_of_week(date) in @fallback_working_days,
      do: %{start_time: @fallback_start_time, end_time: @fallback_end_time, ends_next_day: false},
      else: :closed
  end

  defp opening(date, schedule_id, config) do
    with %{start_time: start_time, end_time: end_time, ends_next_day: ends_next_day} = window <-
           day_opening(date, schedule_id, config),
         true <- Window.valid?(start_time, end_time, ends_next_day) do
      window
    else
      _closed_or_invalid -> :closed
    end
  end

  # The single reading of the schedule for one date. An override outranks the
  # weekly pattern, but only where it names hours of its own: `available`
  # without them means "open, on the usual hours".
  @spec day_opening(Date.t(), integer(), Calculate.availability_config()) :: day_opening()
  defp day_opening(date, schedule_id, config) do
    case lookup_override(date, schedule_id, config) do
      %{override_type: "unavailable"} ->
        :closed

      %{override_type: type, start_time: %Time{}, end_time: %Time{}} = override
      when type in ["custom_hours", "available"] ->
        window_of(override)

      %{override_type: type} when type in ["custom_hours", "available"] ->
        weekly_opening(date, schedule_id, config, :no_hours)

      _no_override ->
        weekly_opening(date, schedule_id, config, :closed)
    end
  end

  # `closed_when_absent` is what a day the weekly pattern does not offer falls
  # back to: closed on its own, but still open where an override has already
  # said the owner is available that day.
  defp weekly_opening(date, schedule_id, config, closed_when_absent) do
    case lookup_day_availability(Date.day_of_week(date), schedule_id, config) do
      %{is_available: true, start_time: %Time{}, end_time: %Time{}} = row -> window_of(row)
      %{is_available: true} -> :no_hours
      _unavailable_or_missing -> closed_when_absent
    end
  end

  # Preloaded rows in tests and older callers may be plain maps without the
  # flag; a missing flag is a same-day window.
  defp window_of(row) do
    %{
      start_time: row.start_time,
      end_time: row.end_time,
      ends_next_day: Map.get(row, :ends_next_day, false) == true
    }
  end

  defp resolve_window(date, window, schedule_id, owner_timezone, config) do
    {start_dt, end_dt} = Window.resolve(window, date, owner_timezone)

    breaks =
      date
      |> weekly_breaks(schedule_id, owner_timezone, config)
      |> Intervals.clip({start_dt, end_dt})

    %{date: date, start_dt: start_dt, end_dt: end_dt, breaks: breaks}
  end

  # A weekday's weekly breaks apply on that date even when an override
  # supplies the hours, as they always have. `lookup_day_availability/3`
  # answers nil for a nil schedule, so the fallback hours carry no breaks.
  defp weekly_breaks(date, schedule_id, owner_timezone, config) do
    case lookup_day_availability(Date.day_of_week(date), schedule_id, config) do
      %{breaks: breaks} = row when is_list(breaks) ->
        window = window_of(row)

        Enum.map(
          breaks,
          &Window.resolve_break(window, {&1.start_time, &1.end_time}, date, owner_timezone)
        )

      _no_breaks ->
        []
    end
  end

  # Data lookup — uses preloaded collections when available, falls back to DB queries

  defp lookup_override(date, schedule_id, %{overrides: overrides}) when is_list(overrides) do
    Enum.find(overrides, &(&1.date == date and &1.schedule_id == schedule_id))
  end

  defp lookup_override(date, schedule_id, _config) do
    AvailabilityOverrideQueries.get_override_by_schedule_and_date(schedule_id, date)
  end

  # Periods are profile-wide, so unlike the override lookup this one is not
  # filtered by schedule: the prefetched list was already resolved from the
  # schedule's profile, and the fallback query makes that hop itself.
  defp lookup_time_off(_dates, _schedule_id, %{time_off: periods}) when is_list(periods),
    do: periods

  defp lookup_time_off(dates, schedule_id, _config),
    do: TimeOffPeriodQueries.list_for_schedule_in_range(schedule_id, dates.first, dates.last)

  @spec lookup_day_availability(integer(), integer() | nil, Calculate.availability_config()) ::
          day_availability() | nil
  defp lookup_day_availability(_day_of_week, nil, _config), do: nil

  defp lookup_day_availability(day_of_week, _schedule_id, %{weekly_schedule: schedule})
       when is_list(schedule) do
    Enum.find(schedule, &(&1.day_of_week == day_of_week))
  end

  defp lookup_day_availability(day_of_week, schedule_id, _config) do
    WeeklySchedule.get_day_availability(schedule_id, day_of_week)
  end
end
