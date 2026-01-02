defmodule Tymeslot.Demo.AvailabilityGenerator do
  @moduledoc """
  Generates synthetic availability for demo users.

  This module creates realistic-looking availability patterns without
  relying on any real calendar data. The availability shifts with time
  so the demo always shows relevant future dates.
  """

  @doc """
  Generates available time slots for a demo user.

  Creates a pattern where:
  - Some slots are always available
  - Some slots are randomly unavailable (simulating existing bookings)
  - Availability is consistent for the same date (deterministic based on date)
  - Patterns shift naturally as time passes
  """
  @spec generate_available_slots(Date.t(), integer(), String.t(), String.t()) ::
          {:ok, list(String.t())}
  def generate_available_slots(date, duration_minutes, user_timezone, owner_timezone) do
    # Convert date to owner's timezone for slot generation
    {:ok, date_in_owner_tz} = DateTime.new(date, ~T[00:00:00], owner_timezone)

    # Generate slots based on business hours (9 AM to 5 PM)
    start_hour = 9
    end_hour = 17

    slots = generate_time_slots(date_in_owner_tz, start_hour, end_hour, duration_minutes)

    # Filter out some slots to simulate existing bookings
    # Use date as seed for consistent randomness
    available_slots = filter_available_slots(slots, date)

    # Convert slots to user's timezone and format as time strings
    time_strings =
      Enum.map(available_slots, fn slot ->
        format_slot_time(slot, user_timezone)
      end)

    {:ok, time_strings}
  end

  defp generate_time_slots(date, start_hour, end_hour, duration_minutes) do
    # Calculate total minutes available
    total_minutes = (end_hour - start_hour) * 60

    # Calculate number of slots
    num_slots = div(total_minutes, duration_minutes)

    # Generate slots
    Enum.map(0..(num_slots - 1), fn index ->
      minutes_offset = index * duration_minutes
      hours_to_add = div(minutes_offset, 60)
      minutes_to_add = rem(minutes_offset, 60)

      start_time =
        DateTime.add(date, start_hour * 3600 + hours_to_add * 3600 + minutes_to_add * 60, :second)

      end_time = DateTime.add(start_time, duration_minutes * 60, :second)

      %{
        start: start_time,
        end: end_time,
        available: true
      }
    end)
  end

  defp filter_available_slots(slots, date) do
    # Use date to seed randomness for consistent results
    {year, month, day} = Date.to_erl(date)
    seed = year * 10_000 + month * 100 + day
    :rand.seed(:exsss, {seed, seed, seed})

    # Keep 60-80% of slots available
    availability_rate = 0.6 + :rand.uniform() * 0.2

    Enum.filter(slots, fn _slot ->
      :rand.uniform() < availability_rate
    end)
  end

  defp format_slot_time(slot, user_timezone) do
    # Convert to user's timezone
    {:ok, user_start} = DateTime.shift_zone(slot.start, user_timezone)

    # Format time to match expected format (e.g., "9:00 am", "2:30 pm")
    user_start
    |> Calendar.strftime("%-I:%M %p")
    |> String.downcase()
  end

  @doc """
  Gets synthetic calendar events for demo users.
  Always returns an empty list since demo users don't have real events.
  """
  @spec get_demo_calendar_events(Date.t(), integer()) :: {:ok, list()}
  def get_demo_calendar_events(_date, _user_id) do
    {:ok, []}
  end

  @doc """
  Checks if a date is available for booking.
  Returns availability based on business days and advance booking settings.
  """
  @spec date_available?(Date.t(), term(), String.t()) :: boolean()
  def date_available?(date, profile, _user_timezone) do
    today = Date.utc_today()

    # Check if date is in the future
    if Date.compare(date, today) == :lt do
      false
    else
      # Check if within advance booking window
      days_ahead = Date.diff(date, today)

      if days_ahead > profile.advance_booking_days do
        false
      else
        # Check if it's a weekday (Mon-Fri)
        day_of_week = Date.day_of_week(date)
        day_of_week in 1..5
      end
    end
  end
end
