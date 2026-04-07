defmodule Tymeslot.Availability.Calculate do
  @moduledoc """
  Main orchestrator for availability calculations.
  Combines business hours, time slots, and conflict detection.
  """

  alias Tymeslot.Availability.{AvailabilityOverrideQueries, WeeklyAvailabilityQueries}
  alias Tymeslot.Availability.{BusinessHours, Conflicts, Events, TimeSlots}
  alias Tymeslot.Utils.DateTimeUtils

  @type availability_config :: %{
          optional(:profile_id) => pos_integer(),
          optional(:max_advance_booking_days) => pos_integer(),
          optional(:duration_minutes) => pos_integer(),
          optional(:buffer_minutes) => non_neg_integer(),
          optional(:weekly_schedule) => list(term()),
          optional(:overrides) => list(term()),
          optional(:fallback_availability_fn) => (Date.t() -> term()) | nil,
          optional(:owner_timezone) => String.t(),
          optional(:min_advance_hours) => non_neg_integer()
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
          [Events.calendar_event()],
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
    profile_id = Map.get(config, :profile_id)

    # Prefetch schedule data once for all adjacent-day lookups
    config = prefetch_schedule_data(config, profile_id, Date.add(date, -1), Date.add(date, 1))

    # Check the selected date and its adjacent days in the owner's timezone,
    # as they might bleed into the attendee's selected date.
    business_hours_windows =
      Enum.flat_map([Date.add(date, -1), date, Date.add(date, 1)], fn d ->
        case BusinessHours.get_business_hours_in_timezone(
               d,
               profile_id,
               owner_timezone,
               user_timezone,
               config
             ) do
          {:ok, %{start_datetime: %DateTime{} = start_dt, end_datetime: %DateTime{} = end_dt}} ->
            if DateTime.to_date(start_dt) == date or DateTime.to_date(end_dt) == date do
              [%{start_dt: start_dt, end_dt: end_dt, date: d}]
            else
              []
            end

          _other ->
            []
        end
      end)

    if Enum.empty?(business_hours_windows) do
      {:ok, []}
    else
      events_in_user_tz =
        Events.convert_events_to_timezone(events, owner_timezone, user_timezone)

      all_available_slots =
        business_hours_windows
        |> Enum.flat_map(fn window ->
          breaks = get_breaks_for_day(window.date, config)

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
        |> Enum.sort()

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
          [Events.calendar_event()],
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

    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)
    max_booking_date = Date.add(today, max_advance_booking_days)
    duration_minutes = Map.get(config, :duration_minutes, 30)

    events_in_user_tz = Events.convert_events_to_timezone(events, owner_timezone, user_timezone)
    profile_id = Map.get(config, :profile_id)

    # Prefetch schedule data once for the entire range (with 1-day padding for adjacent-day checks)
    config =
      config
      |> Map.put(:duration_minutes, duration_minutes)
      |> prefetch_schedule_data(profile_id, Date.add(start_date, -1), Date.add(end_date, 1))

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
          [Events.calendar_event()],
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
    - config: Configuration map with profile_id, max_advance_booking_days, etc.
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

  # Private functions

  # Prefetches weekly schedule and overrides into config to avoid N+1 queries.
  # When profile_id is nil, returns config unchanged (fallback hours are used).
  defp prefetch_schedule_data(config, nil, _start_date, _end_date), do: config

  defp prefetch_schedule_data(config, profile_id, start_date, end_date) do
    config
    |> Map.put_new_lazy(:weekly_schedule, fn ->
      WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(profile_id)
    end)
    |> Map.put_new_lazy(:overrides, fn ->
      AvailabilityOverrideQueries.get_overrides_by_profile_and_date_range(
        profile_id,
        start_date,
        end_date
      )
    end)
  end

  defp get_breaks_for_day(date, config) do
    day_of_week = Date.day_of_week(date)
    profile_id = Map.get(config, :profile_id)

    case BusinessHours.lookup_day_availability(day_of_week, profile_id, config) do
      %{breaks: breaks} when is_list(breaks) ->
        Enum.map(breaks, &{&1.start_time, &1.end_time})

      _other ->
        []
    end
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
    profile_id = Map.get(config, :profile_id)
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)

    is_business_day = BusinessHours.business_day?(date, profile_id, config)
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
    profile_id = Map.get(config, :profile_id)
    owner_timezone = Map.get(config, :owner_timezone, "Etc/UTC")
    user_timezone = now.time_zone

    result =
      BusinessHours.get_business_hours_in_timezone(
        date,
        profile_id,
        owner_timezone,
        user_timezone,
        config
      )

    case result do
      {:ok, %{end_datetime: %DateTime{} = end_dt}} ->
        min_advance_hours = Map.get(config, :min_advance_hours, 0)
        latest_start = DateTime.add(end_dt, -min_advance_hours * 60, :minute)
        DateTime.compare(now, latest_start) != :gt

      _other ->
        false
    end
  end
end
