defmodule Tymeslot.Availability.Conflicts do
  @moduledoc """
  Pure functions for conflict detection and slot filtering.
  """

  alias Tymeslot.Availability.{BusinessHours, TimeSlots}
  alias Tymeslot.Utils.TimeRange

  @doc """
  Filters available slots based on conflicts and booking rules.

  ## Parameters
    - all_slots: List of time slot strings
    - events: List of events in user timezone
    - duration_minutes: Meeting duration in minutes
    - timezone: User timezone
    - date: The date being checked
    - config: Configuration map with buffer_minutes, advance_booking_hours, max_advance_booking_days

  ## Returns
    List of available time slot strings
  """
  @spec filter_available_slots([String.t()], [map()], integer(), String.t(), Date.t(), map()) :: [
          String.t()
        ]
  def filter_available_slots(all_slots, events, duration_minutes, timezone, date, config \\ %{}) do
    buffer_minutes = Map.get(config, :buffer_minutes, 15)
    min_advance_hours = Map.get(config, :min_advance_hours, 3)
    advance_booking_minutes = min_advance_hours * 60
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)

    # Get current time in the same timezone as the slots
    current_time = DateTime.shift_zone!(DateTime.utc_now(), timezone)
    minimum_booking_time = DateTime.add(current_time, advance_booking_minutes, :minute)
    maximum_booking_time = DateTime.add(current_time, max_advance_booking_days * 24 * 60, :minute)

    Enum.filter(all_slots, fn slot ->
      # Parse the slot time and create datetime
      slot_time = TimeSlots.parse_time_slot(slot)
      slot_start = create_datetime_safe(date, slot_time, timezone)
      slot_end = DateTime.add(slot_start, duration_minutes, :minute)

      # Check all booking constraints
      meets_advance_buffer?(slot_start, minimum_booking_time) and
        meets_max_advance?(slot_start, maximum_booking_time) and
        no_event_conflict?(slot_start, slot_end, events, buffer_minutes)
    end)
  end

  @doc """
  Checks if two time ranges overlap.
  Delegates to the shared TimeRange utility.
  """
  defdelegate events_overlap?(slot_start, slot_end, event_start, event_end),
    to: TimeRange,
    as: :overlaps?

  @doc """
  Converts a list of events to a specific timezone.
  """
  @spec convert_events_to_timezone(list(map()), String.t()) :: list(map())
  def convert_events_to_timezone(events, timezone) do
    Enum.map(events, fn event ->
      case {DateTime.shift_zone(event.start_time, timezone),
            DateTime.shift_zone(event.end_time, timezone)} do
        {{:ok, start_tz}, {:ok, end_tz}} ->
          %{event | start_time: start_tz, end_time: end_tz}

        _ ->
          event
      end
    end)
  end

  @doc """
  Checks if a date has available slots given pre-fetched events.
  Used for efficient month view checking.
  """
  @spec date_has_slots_with_events?(Date.t(), String.t(), String.t(), [map()], map()) :: boolean()
  def date_has_slots_with_events?(
        date,
        owner_timezone,
        user_timezone,
        events_in_user_tz,
        config \\ %{}
      ) do
    buffer_minutes = Map.get(config, :buffer_minutes, 15)

    # Define business hours
    {start_time, end_time} = BusinessHours.business_hours_range()

    # Create datetime range in owner's timezone
    owner_start = create_datetime_safe(date, start_time, owner_timezone)
    owner_end = create_datetime_safe(date, end_time, owner_timezone)

    # Convert to user's timezone
    case {DateTime.shift_zone(owner_start, user_timezone),
          DateTime.shift_zone(owner_end, user_timezone)} do
      {{:ok, user_start}, {:ok, user_end}} ->
        # Check if any event blocks the entire business day
        not Enum.any?(events_in_user_tz, fn event ->
          buffered_start = DateTime.add(event.start_time, -buffer_minutes, :minute)
          buffered_end = DateTime.add(event.end_time, buffer_minutes, :minute)

          # Check if this event covers the entire business hours
          DateTime.compare(buffered_start, user_start) != :gt and
            DateTime.compare(buffered_end, user_end) != :lt
        end)

      _ ->
        false
    end
  end

  # Private functions

  defp meets_advance_buffer?(slot_start, minimum_booking_time) do
    DateTime.compare(slot_start, minimum_booking_time) != :lt
  end

  defp meets_max_advance?(slot_start, maximum_booking_time) do
    DateTime.compare(slot_start, maximum_booking_time) != :gt
  end

  defp no_event_conflict?(slot_start, slot_end, events, buffer_minutes) do
    not TimeRange.has_conflict_with_events?(slot_start, slot_end, events, buffer_minutes)
  end

  defp create_datetime_safe(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} ->
        datetime

      {:error, _reason} ->
        # Fallback to UTC if timezone is invalid
        DateTime.new!(date, time, "Etc/UTC")
    end
  end
end
