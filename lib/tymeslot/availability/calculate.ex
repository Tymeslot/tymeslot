defmodule Tymeslot.Availability.Calculate do
  @moduledoc """
  Main orchestrator for availability calculations.
  Combines business hours, time slots, and conflict detection.
  """

  alias Tymeslot.Availability.{AvailabilityOverrideQueries, WeeklyAvailabilityQueries}
  alias Tymeslot.Availability.{BusinessHours, Conflicts, Events, TimeSlots}
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Validation.Constraints

  @type availability_config :: %{
          optional(:schedule_id) => pos_integer(),
          optional(:max_advance_booking_days) => pos_integer(),
          optional(:duration_minutes) => pos_integer(),
          optional(:buffer_minutes) => non_neg_integer(),
          optional(:weekly_schedule) => list(term()),
          optional(:overrides) => list(term()),
          optional(:fallback_availability_fn) => (Date.t() -> term()) | nil,
          optional(:owner_timezone) => String.t(),
          optional(:min_advance_hours) => non_neg_integer(),
          optional(:limit_checker) => (DateTime.t() -> boolean()) | nil
        }

  @typedoc "The three scheduling policy values an `availability_config` carries."
  @type policy_values :: %{
          buffer_minutes: non_neg_integer(),
          min_advance_hours: non_neg_integer(),
          max_advance_booking_days: pos_integer()
        }

  @type calendar_day :: %{
          required(:date) => String.t(),
          required(:day) => integer(),
          required(:available) => boolean(),
          required(:loading) => boolean(),
          required(:past) => boolean(),
          required(:today) => boolean(),
          required(:current_month) => boolean()
        }

  @doc """
  Calculates available time slots for a specific date.

  ## Parameters
    - date: Date to check
    - duration_minutes: Meeting duration in minutes
    - user_timezone: Timezone of the user viewing availability
    - owner_timezone: Timezone of the calendar owner
    - events: List of existing events
    - config: Optional configuration overrides

  ## Returns
    List of available time slot strings
  """
  @spec available_slots(
          Date.t(),
          integer(),
          String.t(),
          String.t(),
          [CalendarEvent.t()],
          availability_config()
        ) :: {:ok, [String.t()]} | {:error, any()}
  def available_slots(
        date,
        duration_minutes,
        user_timezone,
        owner_timezone,
        events,
        config \\ %{}
      ) do
    duration_minutes = duration_minutes |> max(1) |> min(1440)
    schedule_id = Map.get(config, :schedule_id)

    # Prefetch schedule data once for all adjacent-day lookups
    config = prefetch_schedule_data(config, schedule_id, Date.add(date, -1), Date.add(date, 1))

    business_hours_windows =
      BusinessHours.windows_for_target_date(
        date,
        schedule_id,
        owner_timezone,
        user_timezone,
        config
      )

    if Enum.empty?(business_hours_windows) do
      {:ok, []}
    else
      blocking_events = Enum.filter(events, &CalendarEvent.blocking?/1)

      events_in_user_tz =
        Events.convert_events_to_timezone(blocking_events, owner_timezone, user_timezone)

      all_available_slots =
        business_hours_windows
        |> Enum.flat_map(fn window ->
          breaks = BusinessHours.breaks_for_day(window.date, schedule_id, config)

          all_slots =
            TimeSlots.generate_slots_for_range_with_breaks(
              window.start_dt,
              window.end_dt,
              duration_minutes,
              date,
              breaks
            )

          Conflicts.filter_available_slots(
            all_slots,
            events_in_user_tz,
            duration_minutes,
            user_timezone,
            date,
            config
          )
        end)
        |> Enum.uniq()
        |> Enum.sort_by(&TimeSlots.parse_time_slot/1, Time)

      {:ok, all_available_slots}
    end
  end

  @doc """
  Gets availability status for an arbitrary date range.
  Optimized for calendar display where visible dates may span multiple months.

  ## Returns
    Map of date strings to availability boolean
  """
  @spec range_availability(
          Date.t(),
          Date.t(),
          String.t(),
          String.t(),
          [CalendarEvent.t()],
          availability_config()
        ) :: {:ok, %{String.t() => boolean()}}
  def range_availability(
        start_date,
        end_date,
        owner_timezone,
        user_timezone,
        events,
        config \\ %{}
      ) do
    now = DateTimeUtils.now_in_timezone(user_timezone)
    today = DateTime.to_date(now)

    max_advance_booking_days = config_policy(config).max_advance_booking_days
    max_booking_date = Date.add(today, max_advance_booking_days)
    duration_minutes = Map.get(config, :duration_minutes, 30)

    blocking_events = Enum.filter(events, &CalendarEvent.blocking?/1)

    events_in_user_tz =
      Events.convert_events_to_timezone(blocking_events, owner_timezone, user_timezone)

    schedule_id = Map.get(config, :schedule_id)

    # Prefetch schedule data once for the entire range (with 1-day padding for adjacent-day checks)
    config =
      config
      |> Map.put(:duration_minutes, duration_minutes)
      |> prefetch_schedule_data(schedule_id, Date.add(start_date, -1), Date.add(end_date, 1))

    availability_map =
      Enum.reduce(Date.range(start_date, end_date), %{}, fn date, acc ->
        is_outside_range =
          Date.compare(date, today) == :lt or Date.compare(date, max_booking_date) == :gt

        has_slots =
          not is_outside_range and
            Conflicts.date_has_slots_with_events?(
              date,
              owner_timezone,
              user_timezone,
              events_in_user_tz,
              now,
              config
            )

        Map.put(acc, Date.to_string(date), has_slots)
      end)

    {:ok, availability_map}
  end

  @doc """
  Gets availability status for multiple dates in a month.
  Optimized for calendar display.

  Delegates to `range_availability/6` using the first and last day of the month.

  ## Returns
    Map of date strings to availability boolean
  """
  @spec month_availability(
          integer(),
          integer(),
          String.t(),
          String.t(),
          [CalendarEvent.t()],
          availability_config()
        ) :: {:ok, %{String.t() => boolean()}}
  def month_availability(
        year,
        month,
        owner_timezone,
        user_timezone,
        events,
        config \\ %{}
      ) do
    start_date = Date.new!(year, month, 1)
    end_date = Date.end_of_month(start_date)

    range_availability(start_date, end_date, owner_timezone, user_timezone, events, config)
  end

  @doc """
  Computes the 42-day display range for a calendar grid.

  Returns `{start_date, end_date}` covering exactly the dates rendered by
  `get_calendar_days/5` — a 6-week (42-day) window starting on the Sunday
  at or before the first of the month.
  """
  @spec display_range(integer(), integer()) :: {Date.t(), Date.t()}
  def display_range(year, month) do
    first_day = Date.new!(year, month, 1)
    days_before = Date.day_of_week(first_day)
    days_before = if days_before == 7, do: 0, else: days_before
    start_date = Date.add(first_day, -days_before)
    end_date = Date.add(start_date, 41)
    {start_date, end_date}
  end

  @doc """
  Gets calendar days for display in the UI.

  Returns a list of day objects for calendar rendering, including
  availability, current month status, and other display properties.

  ## Parameters
    - user_timezone: Timezone of the user viewing the calendar
    - year: Year to display
    - month: Month to display (1-12)
    - config: Configuration map with schedule_id, max_advance_booking_days, etc.
    - availability_map: Optional map of date strings to boolean availability.
      Can be:
      - nil: Use business hours logic only (fast, but not conflict-aware)
      - :loading: Mark all days as loading state
      - %{}: Use real conflict-aware availability from the map
  """
  @spec get_calendar_days(
          String.t(),
          integer(),
          integer(),
          availability_config(),
          %{String.t() => boolean()} | atom() | nil
        ) :: [calendar_day()]
  def get_calendar_days(user_timezone, year, month, config \\ %{}, availability_map \\ nil) do
    now = DateTimeUtils.now_in_timezone(user_timezone)
    today = DateTime.to_date(now)

    {first_display_date, _end_date} = display_range(year, month)

    Enum.map(0..41, fn offset ->
      date = Date.add(first_display_date, offset)
      date_string = Date.to_string(date)

      is_past = Date.compare(date, today) == :lt

      {is_available, is_loading} =
        determine_availability(date, date_string, today, now, availability_map, config)

      %{
        date: date_string,
        day: date.day,
        available: is_available,
        loading: is_loading,
        past: is_past,
        today: date == today,
        current_month: date.month == month
      }
    end)
  end

  @doc """
  Validates that both date and time have been selected for booking.
  """
  @spec validate_time_selection(term(), term(), term()) :: :ok | {:error, String.t()}
  def validate_time_selection(date, time, _slots) do
    cond do
      date in [nil, ""] -> {:error, "Please select a date"}
      time in [nil, ""] -> {:error, "Please select a time"}
      is_binary(date) and is_binary(time) -> :ok
      true -> {:error, "Please select a date and time"}
    end
  end

  @doc """
  The three scheduling policy values an `availability_config` carries, falling
  back to `Tymeslot.Validation.Constraints.scheduling_policy_defaults/0` for any
  the caller left out.

  Callers build config from a resolved availability schedule. A config assembled
  without one has to behave like a default schedule rather than carry a third
  set of numbers of its own, because the offered slots and the booking-time
  re-check read the policy through different paths and must not disagree.
  """
  @spec config_policy(availability_config()) :: policy_values()
  def config_policy(config) do
    defaults = Constraints.scheduling_policy_defaults()

    %{
      buffer_minutes: Map.get(config, :buffer_minutes, defaults.buffer_minutes),
      min_advance_hours: Map.get(config, :min_advance_hours, defaults.min_advance_hours),
      max_advance_booking_days:
        Map.get(config, :max_advance_booking_days, defaults.advance_booking_days)
    }
  end

  # Private functions

  # Prefetches the schedule's weekly pattern and overrides into config to avoid
  # N+1 queries. A nil schedule id means no schedule could be resolved, and the
  # hard-coded fallback hours are used instead.
  defp prefetch_schedule_data(config, nil, _start_date, _end_date), do: config

  defp prefetch_schedule_data(config, schedule_id, start_date, end_date) do
    config
    |> Map.put_new_lazy(:weekly_schedule, fn ->
      WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(schedule_id)
    end)
    |> Map.put_new_lazy(:overrides, fn ->
      AvailabilityOverrideQueries.get_overrides_by_schedule_and_date_range(
        schedule_id,
        start_date,
        end_date
      )
    end)
  end

  defp determine_availability(date, date_string, today, now, availability_map, config) do
    cond do
      Date.compare(date, today) == :lt ->
        {false, false}

      availability_map == :loading ->
        {false, true}

      is_map(availability_map) ->
        {Map.get(availability_map, date_string, false), false}

      is_function(Map.get(config, :fallback_availability_fn), 1) ->
        {config.fallback_availability_fn.(date), false}

      true ->
        {fallback_day_available?(date, today, now, config), false}
    end
  end

  defp fallback_day_available?(date, today, now, config) do
    schedule_id = Map.get(config, :schedule_id)
    max_advance_booking_days = config_policy(config).max_advance_booking_days

    is_business_day = BusinessHours.business_day?(date, schedule_id, config)
    is_future = Date.compare(date, today) == :gt
    is_today = date == today
    is_within_limit = Date.diff(date, today) <= max_advance_booking_days

    today_available =
      if is_today and is_business_day do
        check_today_fallback_availability(date, now, config)
      else
        false
      end

    (is_future or today_available) and is_business_day and is_within_limit
  end

  defp check_today_fallback_availability(date, now, config) do
    schedule_id = Map.get(config, :schedule_id)
    owner_timezone = Map.get(config, :owner_timezone, "Etc/UTC")
    user_timezone = now.time_zone

    result =
      BusinessHours.get_business_hours_in_timezone(
        date,
        schedule_id,
        owner_timezone,
        user_timezone,
        config
      )

    case result do
      {:ok, %{end_datetime: %DateTime{} = end_dt}} ->
        min_advance_hours = config_policy(config).min_advance_hours
        latest_start = DateTime.add(end_dt, -min_advance_hours * 60, :minute)
        DateTime.compare(now, latest_start) != :gt

      _other ->
        false
    end
  end
end
