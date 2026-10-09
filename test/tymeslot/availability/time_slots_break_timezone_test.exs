defmodule Tymeslot.Availability.TimeSlotsBreakTimezoneTest do
  @moduledoc """
  Breaks belong to the owner's clock, slots to the booker's.

  Break times are stored as the owner's local wall-clock times. The slots are
  listed on the booker's clock, so a break read on the booker's clock instead
  would move the owner's lunch by exactly the offset between the two. The error
  is invisible whenever owner and booker share a zone, which is why every case
  here deliberately does not.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.Window

  # Owner in Europe/Berlin, booker in Europe/London: the booker's clock runs
  # one hour behind the owner's.
  @owner_tz "Europe/Berlin"
  @booker_tz "Europe/London"

  # 2026-09-07 is a Monday.
  @monday ~D[2026-09-07]

  defp monday_config(start_time, end_time, breaks) do
    pure_config(
      days: [
        %{
          day_of_week: 1,
          start_time: start_time,
          end_time: end_time,
          breaks: for({from, to} <- breaks, do: %{start_time: from, end_time: to})
        }
      ]
    )
  end

  describe "a break set by an owner in another timezone" do
    test "hides the owner's lunch, not the booker's" do
      config = monday_config(~T[09:00:00], ~T[17:00:00], [{~T[12:00:00], ~T[13:00:00]}])

      slots = labels(@monday, 30, @owner_tz, @booker_tz, config)

      # Berlin 12:00-13:00 is London 11:00-12:00. That is the hour the owner
      # is away, and the hour the booker must not be offered.
      refute "11:00 AM" in slots
      refute "11:30 AM" in slots

      # London 12:00-13:00 is Berlin 13:00-14:00: the owner is back at their
      # desk, so these must stay on offer. Reading the break on the booker's
      # clock removed exactly these two and kept the two above.
      assert "12:00 PM" in slots
      assert "12:30 PM" in slots
    end

    test "removes only the break, leaving the rest of the day intact" do
      config = monday_config(~T[09:00:00], ~T[17:00:00], [{~T[12:00:00], ~T[13:00:00]}])

      slots = labels(@monday, 30, @owner_tz, @booker_tz, config)

      # Eight owner hours at two slots an hour, less the one-hour break.
      assert length(slots) == 14
      assert List.first(slots) == "8:00 AM"
      assert List.last(slots) == "3:30 PM"
    end

    test "a break outside the window removes nothing" do
      config = monday_config(~T[09:00:00], ~T[12:00:00], [{~T[18:00:00], ~T[19:00:00]}])

      assert length(labels(@monday, 30, @owner_tz, @booker_tz, config)) == 6
    end
  end

  describe "a window that crosses midnight in the booker's zone" do
    # Owner in Asia/Tokyo working 09:00-17:00 JST on Tuesday 8 September;
    # booker in America/Los_Angeles sees that window on the *previous*
    # calendar day, 17:00-01:00 PDT. The owner's date is therefore a day ahead
    # of the booker's date the window starts on, which is why the break must
    # land on the owner's hours and not on the booker's.
    @tokyo "Asia/Tokyo"
    @la "America/Los_Angeles"
    @booker_date ~D[2026-09-07]

    setup do
      # 2026-09-08 is a Tuesday.
      config =
        pure_config(
          days: [
            %{
              day_of_week: 2,
              start_time: ~T[09:00:00],
              end_time: ~T[17:00:00],
              breaks: [%{start_time: ~T[12:00:00], end_time: ~T[13:00:00]}]
            }
          ]
        )

      %{config: config}
    end

    test "resolves the break on the owner's date, not the booker's", %{config: config} do
      slots = labels(@booker_date, 30, @tokyo, @la, config)

      # Tokyo 12:00-13:00 on the 8th is Los Angeles 20:00-21:00 on the 7th.
      refute "8:00 PM" in slots
      refute "8:30 PM" in slots
      assert "7:30 PM" in slots
      assert "9:00 PM" in slots
    end

    # Spec rule: the booker's date lists every start that falls on it, and the
    # meeting need only fit in available time. The 11:30 PM start ends at the
    # booker's midnight and used to be clamped away; it is now offered, and the
    # rest of the window is listed on the next date.
    test "offers the slot that straddles the booker's midnight, with the break on the owner's hours",
         %{config: config} do
      slots = labels(@booker_date, 30, @tokyo, @la, config)
      next_day = labels(Date.add(@booker_date, 1), 30, @tokyo, @la, config)

      assert List.first(slots) == "5:00 PM"
      assert List.last(slots) == "11:30 PM"
      assert next_day == ["12:00 AM", "12:30 AM"]

      # Sixteen half-hours in the eight owner hours, less the two in the break.
      assert length(slots) + length(next_day) == 14
    end
  end

  describe "Window.resolve_break/4 against the owner's zone" do
    # A weekday window with no overnight tail: every break stays on its date.
    @window %{start_time: ~T[09:00:00], end_time: ~T[17:00:00], ends_next_day: false}

    test "anchors each break to the owner's zone" do
      {break_start, break_end} =
        Window.resolve_break(@window, {~T[12:00:00], ~T[13:00:00]}, @monday, @owner_tz)

      assert break_start.time_zone == @owner_tz
      assert DateTime.to_time(break_start) == ~T[12:00:00]
      assert DateTime.to_time(break_end) == ~T[13:00:00]
      # CEST in September.
      assert break_start.utc_offset + break_start.std_offset == 7200
    end

    test "resolves a break that lands in a spring-forward gap" do
      # Europe/London springs forward at 01:00 GMT on 2026-03-29.
      {break_start, _break_end} =
        Window.resolve_break(@window, {~T[01:30:00], ~T[01:45:00]}, ~D[2026-03-29], @booker_tz)

      # Snapped to the instant just after the gap rather than raising.
      assert DateTime.to_time(break_start) == ~T[02:00:00]
    end

    test "resolves an ambiguous break to the first occurrence" do
      # Europe/London falls back at 02:00 BST on 2026-10-25.
      {break_start, _break_end} =
        Window.resolve_break(@window, {~T[01:30:00], ~T[01:45:00]}, ~D[2026-10-25], @booker_tz)

      # The earlier (BST) occurrence.
      assert break_start.std_offset == 3600
    end
  end
end
