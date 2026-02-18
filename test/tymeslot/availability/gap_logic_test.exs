defmodule Tymeslot.Availability.GapLogicTest do
  @moduletag :availability
  @moduledoc """
  @moduletag :availability
  Property-based tests specifically for the gap-finding logic in the Conflicts module.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tymeslot.Availability.Conflicts

  # Fallback business hours from Tymeslot.Availability.BusinessHours
  @fallback_start ~T[11:00:00]
  @fallback_end ~T[19:30:00]

  property "date_has_slots_with_events? correctly handles gaps between events" do
    check all(
            duration <- member_of([15, 30, 45, 60, 90]),
            buffer <- integer(0..30),
            segments <-
              list_of(tuple({integer(1..120), integer(1..120)}), min_length: 1, max_length: 5)
          ) do
      date = get_safe_test_date()
      timezone = "UTC"

      business_start = DateTime.new!(date, @fallback_start, timezone)
      business_end = DateTime.new!(date, @fallback_end, timezone)

      {events, _last_time, has_sufficient_gap} =
        Enum.reduce(segments, {[], business_start, false}, fn {gap_dur, event_dur},
                                                              {acc_events, current_time,
                                                               found_gap} ->
          gap_start = current_time
          gap_end = DateTime.add(gap_start, gap_dur, :minute)

          is_first = current_time == business_start
          required = if is_first, do: duration + buffer, else: duration + 2 * buffer

          can_fit = gap_dur >= required

          event_start = gap_end
          event_end = DateTime.add(event_start, event_dur, :minute)

          if DateTime.compare(event_start, business_end) == :lt do
            new_event = %{start_time: event_start, end_time: event_end}
            {[new_event | acc_events], event_end, found_gap or can_fit}
          else
            {acc_events, current_time, found_gap}
          end
        end)

      last_event_end =
        case events do
          [] -> business_start
          _non_empty -> Enum.max_by(events, & &1.end_time, DateTime).end_time
        end

      final_gap_dur = DateTime.diff(business_end, last_event_end) / 60
      has_sufficient_gap = has_sufficient_gap or final_gap_dur >= duration + buffer

      expected = if events == [], do: true, else: has_sufficient_gap

      result = call_date_has_slots(date, timezone, events, buffer, duration)

      assert result == expected, """
      Gap logic mismatch!
      Duration: #{duration}, Buffer: #{buffer}
      Events: #{inspect(Enum.sort_by(events, & &1.start_time, DateTime))}
      Business window: #{@fallback_start} to #{@fallback_end}
      Expected: #{expected}, Got: #{result}
      """
    end
  end

  describe "specific gap cases" do
    setup do
      %{
        date: get_safe_test_date(),
        timezone: "UTC",
        duration: 30,
        buffer: 10
      }
    end

    test "returns true when there is exactly enough space for one slot", %{
      date: date,
      timezone: timezone,
      duration: duration,
      buffer: buffer
    } do
      # Gap: 12:00 to 12:50 (50 mins)
      # Slot needs 30 + 10(prev buffer) + 10(next buffer) = 50 mins

      events = build_gap_events(date, timezone, ~T[12:50:00])

      assert call_date_has_slots(date, timezone, events, buffer, duration)
    end

    test "returns false when gap is 1 minute too small", %{
      date: date,
      timezone: timezone,
      duration: duration,
      buffer: buffer
    } do
      # Need 50 mins, only have 49
      events = build_gap_events(date, timezone, ~T[12:49:00])

      refute call_date_has_slots(date, timezone, events, buffer, duration)
    end

    test "handles overlapping events correctly", %{
      date: date,
      timezone: timezone,
      duration: duration
    } do
      events = [
        # Block start of day
        %{
          start_time: DateTime.new!(date, ~T[00:00:00], timezone),
          end_time: DateTime.new!(date, ~T[12:00:00], timezone)
        },
        %{
          start_time: DateTime.new!(date, ~T[12:00:00], timezone),
          end_time: DateTime.new!(date, ~T[13:00:00], timezone)
        },
        %{
          start_time: DateTime.new!(date, ~T[12:30:00], timezone),
          end_time: DateTime.new!(date, ~T[14:00:00], timezone)
        },
        %{
          start_time: DateTime.new!(date, ~T[14:30:00], timezone),
          end_time: DateTime.new!(date, ~T[15:00:00], timezone)
        },
        # Block rest of day
        %{
          start_time: DateTime.new!(date, ~T[15:00:00], timezone),
          end_time: DateTime.new!(date, ~T[23:59:59], timezone)
        }
      ]

      assert call_date_has_slots(date, timezone, events, 0, duration)
    end
  end

  defp build_gap_events(date, timezone, second_event_start) do
    [
      %{
        start_time: DateTime.new!(date, ~T[08:00:00], timezone),
        end_time: DateTime.new!(date, ~T[12:00:00], timezone)
      },
      %{
        start_time: DateTime.new!(date, second_event_start, timezone),
        end_time: DateTime.new!(date, ~T[14:00:00], timezone)
      },
      # Block the rest of the day
      %{
        start_time: DateTime.new!(date, ~T[14:00:00], timezone),
        end_time: DateTime.new!(date, ~T[20:00:00], timezone)
      }
    ]
  end

  defp call_date_has_slots(date, timezone, events, buffer, duration) do
    Conflicts.date_has_slots_with_events?(
      date,
      timezone,
      timezone,
      events,
      %{buffer_minutes: buffer, duration_minutes: duration, min_advance_hours: 0}
    )
  end

  defp get_safe_test_date do
    # Get a date in the future that is a Monday (guaranteed business day)
    # and far enough ahead to not be affected by current time/advance booking rules
    Date.utc_today()
    |> Date.add(30)
    |> then(fn date ->
      days_to_monday = 1 - Date.day_of_week(date)
      days_to_monday = if days_to_monday <= 0, do: days_to_monday + 7, else: days_to_monday
      Date.add(date, days_to_monday)
    end)
  end
end
