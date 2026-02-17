defmodule Tymeslot.Availability.Calculate do
  @moduledoc """
  Main orchestrator for availability calculations.
  Combines business hours, time slots, and conflict detection.
  """

  alias Tymeslot.Availability.{BusinessHours, Conflicts, Events, TimeSlots, WeeklySchedule}

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
  @spec available_slots(Date.t(), integer(), String.t(), String.t(), [map()], map()) ::
          {:ok, [String.t()]} | {:error, any()}
  def available_slots(
        date,
        duration_minutes,
        user_timezone,
        owner_timezone,
        events,
        config \\ %{}
      ) do
    # Enforce limits on duration
    duration_minutes = max(duration_minutes, 1)
    duration_minutes = min(duration_minutes, 1440)
    profile_id = Map.get(config, :profile_id)

    # To handle extreme timezone differences (up to 24 hours), we check the selected date
    # and its adjacent days in the owner's timezone, as they might bleed into
    # the attendee's selected date.
    dates_to_check = [
      Date.add(date, -1),
      date,
      Date.add(date, 1)
    ]

    # Collect all business hour windows across these dates that fall on the user's selected date
    business_hours_windows =
      Enum.flat_map(dates_to_check, fn d ->
        result =
          if profile_id do
            BusinessHours.get_business_hours_in_timezone(
              d,
              profile_id,
              owner_timezone,
              user_timezone
            )
          else
            BusinessHours.get_business_hours_in_timezone(d, owner_timezone, user_timezone)
          end

        case result do
          {:ok, %{start_datetime: %DateTime{} = start_dt, end_datetime: %DateTime{} = end_dt}} ->
            # Only include windows that overlap with the user's selected date
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
      # Convert events to user timezone once
      events_in_user_tz =
        Events.convert_events_to_timezone(events, owner_timezone, user_timezone)

      all_available_slots =
        Enum.flat_map(business_hours_windows, fn window ->
          generate_and_filter_slots_for_window(
            window.start_dt,
            window.end_dt,
            window.date,
            date,
            duration_minutes,
            user_timezone,
            events_in_user_tz,
            config
          )
        end)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, all_available_slots}
    end
  end

  defp generate_and_filter_slots_for_window(
         start_dt,
         end_dt,
         owner_date,
         user_date,
         duration_minutes,
         user_timezone,
         events_in_user_tz,
         config
       ) do
    # Get breaks for the owner's date
    breaks = get_breaks_for_day(owner_date, config)

    # Generate slots based on the datetime range, excluding breaks
    all_slots =
      TimeSlots.generate_slots_for_range_with_breaks(
        start_dt,
        end_dt,
        duration_minutes,
        user_date,
        breaks
      )

    # Filter out slots that conflict with existing events
    Conflicts.filter_available_slots(
      all_slots,
      events_in_user_tz,
      duration_minutes,
      user_timezone,
      user_date,
      config
    )
  end

  @doc """
  Gets availability status for multiple dates in a month.
  Optimized for calendar display.

  ## Returns
    Map of date strings to availability boolean
  """
  @spec month_availability(integer(), integer(), String.t(), String.t(), [map()], map()) ::
          {:ok, map()}
  def month_availability(
        year,
        month,
        owner_timezone,
        user_timezone,
        events,
        config \\ %{}
      ) do
    # Get the date range for the month
    start_date = Date.new!(year, month, 1)
    end_date = Date.end_of_month(start_date)

    # Get today's date in user timezone
    today =
      case DateTime.now(user_timezone) do
        {:ok, dt} -> DateTime.to_date(dt)
        _other -> Date.utc_today()
      end

    # Get max booking date
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)
    max_booking_date = Date.add(today, max_advance_booking_days)

    # Convert events to user timezone once
    events_in_user_tz = Events.convert_events_to_timezone(events, owner_timezone, user_timezone)

    # Read duration once (if present)
    duration_minutes = Map.get(config, :duration_minutes, 30)

    # Check each date in the month
    availability_map =
      Enum.reduce(Date.range(start_date, end_date), %{}, fn date, acc ->
        date_string = Date.to_string(date)

        is_outside_range =
          Date.compare(date, today) == :lt or Date.compare(date, max_booking_date) == :gt

        has_slots =
          not is_outside_range and
            Conflicts.date_has_slots_with_events?(
              date,
              owner_timezone,
              user_timezone,
              events_in_user_tz,
              Map.put(config, :duration_minutes, duration_minutes)
            )

        Map.put(acc, date_string, has_slots)
      end)

    {:ok, availability_map}
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

  ## Examples

      # Fast render with business hours only
      get_calendar_days("America/New_York", 2026, 1, %{profile_id: 1})

      # With real availability data
      get_calendar_days("America/New_York", 2026, 1, %{profile_id: 1}, %{"2026-01-15" => true})

      # Loading state
      get_calendar_days("America/New_York", 2026, 1, %{profile_id: 1}, :loading)
  """
  @spec get_calendar_days(String.t(), integer(), integer(), map(), map() | atom() | nil) ::
          list(map())
  def get_calendar_days(user_timezone, year, month, config \\ %{}, availability_map \\ nil) do
    # Get today and current time in user's timezone
    {today, now} =
      case DateTime.now(user_timezone) do
        {:ok, dt} -> {DateTime.to_date(dt), dt}
        _other -> {Date.utc_today(), DateTime.utc_now()}
      end

    # Create date for the given year/month
    start_of_month = Date.new!(year, month, 1)

    # Get the first day to display (Sunday of the week containing the 1st)
    first_day = start_of_month
    days_before = Date.day_of_week(first_day)
    days_before = if days_before == 7, do: 0, else: days_before
    first_display_date = Date.add(first_day, -days_before)

    # Generate 42 days (6 weeks) for consistent calendar display
    Enum.map(0..41, fn offset ->
      date = Date.add(first_display_date, offset)
      date_string = Date.to_string(date)

      is_past = Date.compare(date, today) == :lt

      # Determine availability based on availability_map state
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
  Used in booking workflow validation.
  """
  @spec validate_time_selection(String.t() | nil, String.t() | nil, list()) ::
          :ok | {:error, String.t()}
  def validate_time_selection(nil, _time, _slots), do: {:error, "Please select a date"}

  @spec validate_time_selection(String.t(), String.t() | nil, list()) ::
          :ok | {:error, String.t()}
  def validate_time_selection("", _time, _slots), do: {:error, "Please select a date"}

  @spec validate_time_selection(String.t(), String.t() | nil, list()) ::
          :ok | {:error, String.t()}
  def validate_time_selection(_date, nil, _slots), do: {:error, "Please select a time"}
  @spec validate_time_selection(String.t(), String.t(), list()) :: :ok | {:error, String.t()}
  def validate_time_selection(_date, "", _slots), do: {:error, "Please select a time"}

  @spec validate_time_selection(String.t(), String.t(), list()) :: :ok | {:error, String.t()}
  def validate_time_selection(date, time, slots) when is_list(slots) do
    if time_slot_available?(date, time, slots) do
      :ok
    else
      {:error, "Selected time is no longer available"}
    end
  end

  @spec validate_time_selection(term(), term(), term()) :: {:error, String.t()}
  def validate_time_selection(_date, _time, _slots), do: {:error, "Please select a date and time"}

  @doc """
  Checks if a specific time slot is available.
  """
  @spec time_slot_available?(String.t(), String.t(), list()) :: boolean()
  def time_slot_available?(date, time, slots)
      when is_binary(date) and is_binary(time) and is_list(slots) do
    # For validation, we just need to confirm that selections exist
    # The actual availability is checked during booking submission
    true
  end

  @spec time_slot_available?(term(), term(), term()) :: boolean()
  def time_slot_available?(_date, _time, _slots), do: false

  # Private functions

  defp get_breaks_for_day(date, config) do
    with profile_id when is_integer(profile_id) <- Map.get(config, :profile_id),
         day_of_week <- Date.day_of_week(date),
         %{breaks: breaks} when is_list(breaks) <-
           WeeklySchedule.get_day_availability(profile_id, day_of_week) do
      # Convert breaks to the format expected by TimeSlots
      Enum.map(breaks, fn break ->
        {break.start_time, break.end_time}
      end)
    else
      _other -> []
    end
  end

  defp determine_availability(date, date_string, today, now, availability_map, config) do
    cond do
      # Past dates are never available
      Date.compare(date, today) == :lt ->
        {false, false}

      # Loading state: mark as loading
      availability_map == :loading ->
        {false, true}

      # Real availability data provided: use it
      is_map(availability_map) ->
        {Map.get(availability_map, date_string, false), false}

      # If a custom fallback checker is provided, use it
      is_function(Map.get(config, :fallback_availability_fn), 1) ->
        {config.fallback_availability_fn.(date), false}

      # Default: No availability map, use business hours logic
      true ->
        {fallback_day_available?(date, today, now, config), false}
    end
  end

  defp fallback_day_available?(date, today, now, config) do
    profile_id = Map.get(config, :profile_id)
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)

    is_business_day =
      if profile_id do
        BusinessHours.business_day?(date, profile_id)
      else
        BusinessHours.business_day?(date)
      end

    is_future = Date.compare(date, today) == :gt
    is_today = date == today
    is_within_limit = Date.diff(date, today) <= max_advance_booking_days

    # If it's today, we need to check if business hours have already passed
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
      if profile_id do
        BusinessHours.get_business_hours_in_timezone(
          date,
          profile_id,
          owner_timezone,
          user_timezone
        )
      else
        BusinessHours.get_business_hours_in_timezone(
          date,
          owner_timezone,
          user_timezone
        )
      end

    case result do
      {:ok, %{end_datetime: %DateTime{} = end_dt}} ->
        # Today is available if current time is before business end time (minus min_advance_hours)
        min_advance_hours = Map.get(config, :min_advance_hours, 0)
        latest_start = DateTime.add(end_dt, -min_advance_hours * 60, :minute)
        DateTime.compare(now, latest_start) != :gt

      _other ->
        false
    end
  end
end
