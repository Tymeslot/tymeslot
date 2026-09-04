defmodule Tymeslot.Availability.TimeSlotsBreakTimezoneTest do
  @moduledoc """
  Breaks belong to the owner's clock, slots to the booker's.

  Break times are stored as the owner's local wall-clock times. The window a
  slot grid is built from has already been shifted into the booker's zone, so
  resolving a break against that window puts the owner's lunch on the booker's
  clock and moves it by exactly the offset between the two. The error is
  invisible whenever owner and booker share a zone, which is why every case
  here deliberately does not.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.TimeSlots

  # Owner in Europe/Berlin, booker in Europe/London: the booker's clock runs
  # one hour behind the owner's.
  @owner_tz "Europe/Berlin"
  @booker_tz "Europe/London"

  describe "a break set by an owner in another timezone" do
    setup do
      date = ~D[2026-09-07]

      window = fn start_time, end_time ->
        {
          date |> DateTime.new!(start_time, @owner_tz) |> DateTime.shift_zone!(@booker_tz),
          date |> DateTime.new!(end_time, @owner_tz) |> DateTime.shift_zone!(@booker_tz)
        }
      end

      {:ok, date: date, window: window}
    end

    test "hides the owner's lunch, not the booker's", %{date: date, window: window} do
      {start_dt, end_dt} = window.(~T[09:00:00], ~T[17:00:00])
      breaks = TimeSlots.resolve_breaks([{~T[12:00:00], ~T[13:00:00]}], date, @owner_tz)

      slots =
        TimeSlots.generate_slots_for_range_with_breaks(
          start_dt,
          end_dt,
          30,
          DateTime.to_date(start_dt),
          breaks
        )

      # Berlin 12:00-13:00 is London 11:00-12:00. That is the hour the owner
      # is away, and the hour the booker must not be offered.
      refute "11:00 AM" in slots
      refute "11:30 AM" in slots

      # London 12:00-13:00 is Berlin 13:00-14:00: the owner is back at their
      # desk, so these must stay on offer. Resolving the break on the booker's
      # clock removed exactly these two and kept the two above.
      assert "12:00 PM" in slots
      assert "12:30 PM" in slots
    end

    test "removes only the break, leaving the rest of the day intact", %{
      date: date,
      window: window
    } do
      {start_dt, end_dt} = window.(~T[09:00:00], ~T[17:00:00])
      breaks = TimeSlots.resolve_breaks([{~T[12:00:00], ~T[13:00:00]}], date, @owner_tz)

      slots =
        TimeSlots.generate_slots_for_range_with_breaks(
          start_dt,
          end_dt,
          30,
          DateTime.to_date(start_dt),
          breaks
        )

      # Eight owner hours at two slots an hour, less the one-hour break.
      assert length(slots) == 14
      assert List.first(slots) == "8:00 AM"
      assert List.last(slots) == "3:30 PM"
    end

    test "a break outside the window removes nothing", %{date: date, window: window} do
      {start_dt, end_dt} = window.(~T[09:00:00], ~T[12:00:00])
      breaks = TimeSlots.resolve_breaks([{~T[18:00:00], ~T[19:00:00]}], date, @owner_tz)

      slots =
        TimeSlots.generate_slots_for_range_with_breaks(
          start_dt,
          end_dt,
          30,
          DateTime.to_date(start_dt),
          breaks
        )

      assert length(slots) == 6
    end
  end

  describe "a window that crosses midnight in the booker's zone" do
    # Owner in Asia/Tokyo working 09:00-17:00 JST; booker in America/Los_Angeles
    # sees that window on the *previous* calendar day, 17:00-01:00 PDT. The
    # owner-frame date is therefore a day ahead of the booker-frame date the
    # window starts on, which is why the break must be resolved against the
    # date the window was read for and not against the window's own start.
    @tokyo "Asia/Tokyo"
    @la "America/Los_Angeles"

    test "resolves the break on the owner's date, not the booker's" do
      owner_date = ~D[2026-09-08]

      start_dt =
        owner_date |> DateTime.new!(~T[09:00:00], @tokyo) |> DateTime.shift_zone!(@la)

      end_dt =
        owner_date |> DateTime.new!(~T[17:00:00], @tokyo) |> DateTime.shift_zone!(@la)

      # The booker sees this window starting on 2026-09-07, a day earlier.
      assert DateTime.to_date(start_dt) == ~D[2026-09-07]
      refute DateTime.to_date(start_dt) == owner_date

      breaks = TimeSlots.resolve_breaks([{~T[12:00:00], ~T[13:00:00]}], owner_date, @tokyo)

      slots =
        TimeSlots.generate_slots_for_range_with_breaks(
          start_dt,
          end_dt,
          30,
          DateTime.to_date(start_dt),
          breaks
        )

      # Tokyo 12:00-13:00 on the 8th is Los Angeles 20:00-21:00 on the 7th.
      refute "8:00 PM" in slots
      refute "8:30 PM" in slots
      assert "7:30 PM" in slots
      assert "9:00 PM" in slots
    end

    test "taking the date off the booker-side window would move the break a day" do
      owner_date = ~D[2026-09-08]

      start_dt =
        owner_date |> DateTime.new!(~T[09:00:00], @tokyo) |> DateTime.shift_zone!(@la)

      correct = TimeSlots.resolve_breaks([{~T[12:00:00], ~T[13:00:00]}], owner_date, @tokyo)

      wrong =
        TimeSlots.resolve_breaks(
          [{~T[12:00:00], ~T[13:00:00]}],
          DateTime.to_date(start_dt),
          @tokyo
        )

      [{correct_start, _correct_end}] = correct
      [{wrong_start, _wrong_end}] = wrong

      # A full day apart: the trap this plumbing exists to avoid.
      assert DateTime.diff(correct_start, wrong_start, :hour) == 24
    end
  end

  describe "resolve_breaks/3" do
    test "anchors each break to the owner's zone" do
      [{break_start, break_end}] =
        TimeSlots.resolve_breaks([{~T[12:00:00], ~T[13:00:00]}], ~D[2026-09-07], @owner_tz)

      assert break_start.time_zone == @owner_tz
      assert DateTime.to_time(break_start) == ~T[12:00:00]
      assert DateTime.to_time(break_end) == ~T[13:00:00]
      # CEST in September.
      assert break_start.utc_offset + break_start.std_offset == 7200
    end

    test "resolves a break that lands in a spring-forward gap" do
      # Europe/London springs forward at 01:00 GMT on 2026-03-29.
      [{break_start, _break_end}] =
        TimeSlots.resolve_breaks([{~T[01:30:00], ~T[01:45:00]}], ~D[2026-03-29], @booker_tz)

      # Snapped to the instant just after the gap rather than raising.
      assert DateTime.to_time(break_start) == ~T[02:00:00]
    end

    test "resolves an ambiguous break to the first occurrence" do
      # Europe/London falls back at 02:00 BST on 2026-10-25.
      [{break_start, _break_end}] =
        TimeSlots.resolve_breaks([{~T[01:30:00], ~T[01:45:00]}], ~D[2026-10-25], @booker_tz)

      # The earlier (BST) occurrence.
      assert break_start.std_offset == 3600
    end

    test "returns an empty list unchanged" do
      assert TimeSlots.resolve_breaks([], ~D[2026-09-07], @owner_tz) == []
    end
  end
end
