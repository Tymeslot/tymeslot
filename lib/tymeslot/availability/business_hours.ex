defmodule Tymeslot.Availability.BusinessHours do
  @moduledoc """
  Pure functions for business hours calculations.
  Handles business hours definitions and timezone conversions.
  Uses the weekly availability of a named availability schedule.
  """

  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Availability.TimeOffPeriodQueries
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Availability.WeeklySchedule
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
          optional(:breaks) => list(term())
        }

  @typedoc "Business hours window for a specific date, with datetimes in the attendee's timezone."
  @type business_hours_result :: %{
          required(:start_datetime) => DateTime.t() | nil,
          required(:end_datetime) => DateTime.t() | nil,
          required(:selected_date) => Date.t()
        }

  @doc """
  Gets the business hours for a date in the user's timezone.

  When `config` contains `:weekly_schedule` and/or `:overrides`, those
  preloaded collections are used instead of issuing per-date DB queries.

  Returns a map with start_datetime, end_datetime, and selected_date.
  For unavailable days, returns nil for start and end datetimes.
  """
  @spec get_business_hours_in_timezone(
          Date.t(),
          integer() | nil,
          String.t(),
          String.t(),
          Calculate.availability_config()
        ) :: {:ok, business_hours_result()} | {:error, String.t()}
  def get_business_hours_in_timezone(
        date,
        schedule_id,
        owner_timezone,
        user_timezone,
        config \\ %{}
      )

  def get_business_hours_in_timezone(date, nil, owner_timezone, user_timezone, _config) do
    get_business_hours_in_timezone_fallback(date, owner_timezone, user_timezone)
  end

  def get_business_hours_in_timezone(date, schedule_id, owner_timezone, user_timezone, config) do
    if TimeOff.all_day?(lookup_time_off(date, schedule_id, config), date) do
      {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
    else
      hours_from_schedule(date, schedule_id, owner_timezone, user_timezone, config)
    end
  end

  # Time off is checked before this is reached, and deliberately outranks the
  # override below: a period is profile-wide, so one schedule's `available`
  # exception must not reopen a day the owner is away for.
  defp hours_from_schedule(date, schedule_id, owner_timezone, user_timezone, config) do
    case day_opening(date, schedule_id, config) do
      {start_time, end_time} ->
        convert_business_hours_to_user_timezone(
          date,
          start_time,
          end_time,
          owner_timezone,
          user_timezone
        )

      _closed_or_without_hours ->
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
    end
  end

  @typedoc """
  What the schedule alone says about a date, before time off is taken out of
  it: the `{start_time, end_time}` window it opens in the owner's own clock,
  `:closed`, or `:no_hours` for a day marked available that names no window
  to offer.
  """
  @type day_opening :: {Time.t(), Time.t()} | :closed | :no_hours

  # The single reading of the schedule for one date, so the hours a day offers
  # and the answer to whether it is a business day cannot drift apart. An
  # override outranks the weekly pattern, but only where it names hours of its
  # own: `available` without them means "open, on the usual hours".
  @spec day_opening(Date.t(), integer(), Calculate.availability_config()) :: day_opening()
  defp day_opening(date, schedule_id, config) do
    case lookup_override(date, schedule_id, config) do
      %{override_type: "unavailable"} ->
        :closed

      %{override_type: type, start_time: %Time{} = start_time, end_time: %Time{} = end_time}
      when type in ["custom_hours", "available"] ->
        {start_time, end_time}

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
      %{is_available: true, start_time: %Time{} = start_time, end_time: %Time{} = end_time} ->
        {start_time, end_time}

      %{is_available: true} ->
        :no_hours

      _unavailable_or_missing ->
        closed_when_absent
    end
  end

  @typedoc "A business-hours window for a single day, expressed in the user's timezone."
  @type slot_window :: %{
          required(:start_dt) => DateTime.t(),
          required(:end_dt) => DateTime.t(),
          required(:date) => Date.t()
        }

  @doc """
  Returns the business-hours windows that can produce slots on `target_date`
  in the user's timezone. Adjacent days are considered because business hours
  in the owner's timezone may bleed across midnight in the user's timezone.

  A day whose business hours could not be read (see
  `windows_for_target_date_or_error/5`) is silently dropped here, same as a
  day with no offered hours. Callers that need to tell those two cases apart
  — a genuine "not offered" from a schedule that could not be read — must use
  `windows_for_target_date_or_error/5` instead.
  """
  @spec windows_for_target_date(
          Date.t(),
          integer() | nil,
          String.t(),
          String.t(),
          Calculate.availability_config()
        ) :: [slot_window()]
  def windows_for_target_date(target_date, schedule_id, owner_timezone, user_timezone, config) do
    case windows_for_target_date_or_error(
           target_date,
           schedule_id,
           owner_timezone,
           user_timezone,
           config
         ) do
      {:ok, windows} -> windows
      {:error, _reason} -> []
    end
  end

  @doc """
  Same windows as `windows_for_target_date/5`, but returns `{:error, reason}`
  instead of an empty list when a day's business hours could not be
  converted to the user's timezone, so a schedule-read failure (an unknown
  or renamed timezone, for example) is distinguishable from a day that
  genuinely offers no hours.
  """
  @spec windows_for_target_date_or_error(
          Date.t(),
          integer() | nil,
          String.t(),
          String.t(),
          Calculate.availability_config()
        ) :: {:ok, [slot_window()]} | {:error, term()}
  def windows_for_target_date_or_error(
        target_date,
        schedule_id,
        owner_timezone,
        user_timezone,
        config
      ) do
    dates = [Date.add(target_date, -1), target_date, Date.add(target_date, 1)]

    reduced =
      Enum.reduce_while(dates, {:ok, []}, fn d, {:ok, acc} ->
        case get_business_hours_in_timezone(d, schedule_id, owner_timezone, user_timezone, config) do
          {:ok, %{start_datetime: %DateTime{} = start_dt, end_datetime: %DateTime{} = end_dt}} ->
            if DateTime.to_date(start_dt) == target_date or
                 DateTime.to_date(end_dt) == target_date do
              {:cont, {:ok, [%{start_dt: start_dt, end_dt: end_dt, date: d} | acc]}}
            else
              {:cont, {:ok, acc}}
            end

          {:ok, %{start_datetime: nil, end_datetime: nil}} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case reduced do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the windows a date is *not* bookable inside its business hours, as a
  list of `{start_time, end_time}` tuples, reading from the preloaded weekly
  schedule when available.

  Two sources feed it: the weekly pattern's recurring breaks, and the part-day
  edges of any time-off period covering the date. Both are excluded from the
  same slot grid by the same code, so a half-day of holiday behaves exactly
  like a one-off lunch break — which is what it is. Whole days of time off do
  not appear here; `get_business_hours_in_timezone/5` has already refused those
  outright.
  """
  @spec breaks_for_day(Date.t(), integer() | nil, Calculate.availability_config()) ::
          [{Time.t(), Time.t()}]
  def breaks_for_day(date, schedule_id, config) do
    day_of_week = Date.day_of_week(date)

    weekly_breaks =
      case lookup_day_availability(day_of_week, schedule_id, config) do
        %{breaks: breaks} when is_list(breaks) ->
          Enum.map(breaks, &{&1.start_time, &1.end_time})

        _other ->
          []
      end

    weekly_breaks ++ TimeOff.windows_for_day(lookup_time_off(date, schedule_id, config), date)
  end

  @doc """
  The day's breaks as absolute instants on the owner's clock.

  `breaks_for_day/3` returns bare `Time` structs, which mean nothing until
  they are anchored to a date and a zone. Both have to be the owner's: the
  window a slot grid is built from has already been shifted into the booker's
  zone, so resolving there moves the owner's break by the offset between the
  two clocks.

  `date` is the owner-frame date the breaks were read for — a window's own
  `:date`, not the date its `start_dt` falls on in the booker's zone, which
  can be a day earlier.
  """
  @spec resolved_breaks_for_day(
          Date.t(),
          integer() | nil,
          String.t(),
          Calculate.availability_config()
        ) :: [{DateTime.t(), DateTime.t()}]
  def resolved_breaks_for_day(date, schedule_id, owner_timezone, config) do
    date
    |> breaks_for_day(schedule_id, config)
    |> TimeSlots.resolve_breaks(date, owner_timezone)
  end

  # Fallback for callers with no resolvable availability schedule.
  # Uses the hard-coded fallback hours when no schedule is resolvable.
  @spec get_business_hours_in_timezone_fallback(Date.t(), String.t(), String.t()) ::
          {:ok, business_hours_result()}
  defp get_business_hours_in_timezone_fallback(date, owner_timezone, user_timezone) do
    case Date.day_of_week(date) do
      day when day in @fallback_working_days ->
        convert_business_hours_to_user_timezone(
          date,
          @fallback_start_time,
          @fallback_end_time,
          owner_timezone,
          user_timezone
        )

      _other ->
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
    end
  end

  @doc """
  Checks if a given date is a business day within a schedule.

  The question asked is whether anything is left of the day, not whether one
  period swallowed it whole: part-day periods that between them cover the
  schedule's whole window leave nothing to book, and a day offering nothing
  must not be drawn as one that does. A day blocked in full is the degenerate
  case of the same reading.

  Accepts preloaded data via `config` to avoid per-date DB queries.
  """
  @spec business_day?(Date.t(), integer() | nil, Calculate.availability_config()) :: boolean()
  def business_day?(date, schedule_id, config \\ %{})

  def business_day?(date, nil, _config) do
    Date.day_of_week(date) in @fallback_working_days
  end

  def business_day?(date, schedule_id, config) do
    # Read once and passed on: this runs per rendered day on the week strip's
    # fallback path, which exists precisely to avoid a query per date.
    periods = lookup_time_off(date, schedule_id, config)

    not TimeOff.all_day?(periods, date) and
      date |> day_opening(schedule_id, config) |> open_after_time_off?(periods, date)
  end

  defp open_after_time_off?(:closed, _periods, _date), do: false
  defp open_after_time_off?(:no_hours, _periods, _date), do: true

  defp open_after_time_off?({_start_time, _end_time} = window, periods, date) do
    bookable_time_left?(window, TimeOff.windows_for_day(periods, date))
  end

  # Whether any of `window` survives `blocked`. The blocked windows are walked
  # in order behind a cursor: one that reaches the cursor pushes it to its own
  # end, one that starts later leaves a gap and the cursor stays in it. Time is
  # left over exactly when the cursor never reaches the window's end.
  defp bookable_time_left?({window_start, window_end}, blocked) do
    cursor =
      blocked
      |> Enum.sort_by(fn {from, _to} -> from end, Time)
      |> Enum.reduce(window_start, fn {from, to}, cursor ->
        if Time.compare(from, cursor) != :gt and Time.compare(to, cursor) == :gt,
          do: to,
          else: cursor
      end)

    Time.compare(cursor, window_end) == :lt
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
  defp lookup_time_off(_date, _schedule_id, %{time_off: periods}) when is_list(periods),
    do: periods

  defp lookup_time_off(_date, nil, _config), do: []

  defp lookup_time_off(date, schedule_id, _config) do
    TimeOffPeriodQueries.list_for_schedule_in_range(schedule_id, date, date)
  end

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

  # Private functions

  defp convert_business_hours_to_user_timezone(
         date,
         start_time,
         end_time,
         owner_timezone,
         user_timezone
       ) do
    owner_start = DateTimeUtils.create_datetime_safe(date, start_time, owner_timezone)
    owner_end = DateTimeUtils.create_datetime_safe(date, end_time, owner_timezone)

    with {:ok, user_start} <- DateTime.shift_zone(owner_start, user_timezone),
         {:ok, user_end} <- DateTime.shift_zone(owner_end, user_timezone) do
      {:ok, %{start_datetime: user_start, end_datetime: user_end, selected_date: date}}
    else
      _other -> {:error, "Failed to convert business hours to user timezone"}
    end
  end
end
