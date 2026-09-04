defmodule Tymeslot.Availability.CalculateBreakTimezoneTest do
  @moduledoc """
  The booking page's own answer, for an owner and a booker on different clocks.

  `TimeSlotsBreakTimezoneTest` pins the slot grid in isolation; this pins the
  composition that actually reaches a visitor, where the owner's breaks are
  read for one date and the window they filter has been shifted into the
  booker's zone. Both halves are needed: the grid can be right about the frame
  it is handed and still be handed the wrong one.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Conflicts

  # 2026-09-07 is a Monday.
  @monday ~D[2026-09-07]

  defp schedule(breaks) do
    [
      %{
        day_of_week: 1,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00],
        breaks: breaks
      },
      %{
        day_of_week: 2,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00],
        breaks: breaks
      }
    ]
  end

  defp config(breaks) do
    %{
      schedule_id: 1,
      weekly_schedule: schedule(breaks),
      # Both prefetch keys supplied, so no query is made and the module stays
      # a pure calculation under test (`prefetch_schedule_data/4` lets an
      # existing key win).
      overrides: [],
      min_advance_hours: 0,
      max_advance_booking_days: 3650,
      buffer_minutes: 0
    }
  end

  describe "an owner whose booker is one hour behind" do
    test "offers the hour after the owner's lunch and withholds the lunch itself" do
      lunch = [%{start_time: ~T[12:00:00], end_time: ~T[13:00:00]}]

      {:ok, slots} =
        Calculate.available_slots(
          @monday,
          30,
          "Europe/London",
          "Europe/Berlin",
          [],
          config(lunch)
        )

      # Berlin 12:00-13:00 is London 11:00-12:00.
      refute "11:00 AM" in slots
      refute "11:30 AM" in slots

      # Berlin 13:00-14:00 is London 12:00-13:00: the owner is available.
      assert "12:00 PM" in slots
      assert "12:30 PM" in slots

      # The window itself is intact either side of the break.
      assert "8:00 AM" in slots
      assert "3:30 PM" in slots
    end

    test "a booker sharing the owner's clock sees the break at the same wall time" do
      lunch = [%{start_time: ~T[12:00:00], end_time: ~T[13:00:00]}]

      {:ok, slots} =
        Calculate.available_slots(
          @monday,
          30,
          "Europe/Berlin",
          "Europe/Berlin",
          [],
          config(lunch)
        )

      refute "12:00 PM" in slots
      refute "12:30 PM" in slots
      assert "11:30 AM" in slots
      assert "1:00 PM" in slots
    end
  end

  describe "an owner whose window crosses midnight in the booker's zone" do
    # Tokyo 09:00-17:00 is 17:00-01:00 the previous day in Los Angeles, so the
    # date the breaks were read for is a day ahead of the date the booker's
    # window starts on. Resolving the break against the window's own start
    # would move it a full day and stop it filtering anything.
    test "still hides the owner's lunch" do
      lunch = [%{start_time: ~T[12:00:00], end_time: ~T[13:00:00]}]

      {:ok, slots} =
        Calculate.available_slots(
          ~D[2026-09-07],
          30,
          "America/Los_Angeles",
          "Asia/Tokyo",
          [],
          config(lunch)
        )

      assert slots != []

      # Tokyo 12:00-13:00 on the 8th is Los Angeles 20:00-21:00 on the 7th.
      refute "8:00 PM" in slots
      refute "8:30 PM" in slots
      assert "7:30 PM" in slots
      assert "9:00 PM" in slots
    end
  end

  describe "the calendar grid's own answer" do
    # `Conflicts.date_has_slots_with_events?/6` feeds the same window and the
    # same breaks into the same filter, so the grid and the time picker have
    # to agree. A day whose only offered hour is entirely consumed by a break
    # is the case where the frame decides the boolean: read on the booker's
    # clock the break misses the window, and the grid lights a day up that
    # offers nothing.
    defp narrow_config(breaks) do
      %{
        schedule_id: 1,
        weekly_schedule: [
          %{
            day_of_week: 1,
            is_available: true,
            start_time: ~T[12:00:00],
            end_time: ~T[13:00:00],
            breaks: breaks
          }
        ],
        overrides: [],
        duration_minutes: 30,
        min_advance_hours: 0,
        max_advance_booking_days: 3650,
        buffer_minutes: 0
      }
    end

    @now DateTime.new!(~D[2026-09-01], ~T[00:00:00], "Etc/UTC")

    test "marks the day unavailable when the owner's break covers the only hour" do
      covering = [%{start_time: ~T[12:00:00], end_time: ~T[13:00:00]}]

      refute Conflicts.date_has_slots_with_events?(
               @monday,
               "Europe/Berlin",
               "Europe/London",
               [],
               @now,
               narrow_config(covering)
             )
    end

    test "still marks it available when the break falls outside that hour" do
      elsewhere = [%{start_time: ~T[15:00:00], end_time: ~T[16:00:00]}]

      assert Conflicts.date_has_slots_with_events?(
               @monday,
               "Europe/Berlin",
               "Europe/London",
               [],
               @now,
               narrow_config(elsewhere)
             )
    end
  end
end
