defmodule Tymeslot.Availability.TimeSlotsOwnerAnchorTest do
  @moduledoc """
  Tests for the clock an explicit slot interval anchors its grid to.

  The availability pipeline shifts the owner's business-hours window into the
  booker's timezone before generating slots, so by the time
  `TimeSlots.generate_slots_for_range_with_breaks/7` sees a window it is
  carrying the booker's wall clock. The interval, however, is the owner's
  setting and means "this far apart, on my clock", so alignment reads the
  owner's timezone instead. These cases are the ones where the two clocks
  differ; `Tymeslot.Availability.TimeSlotsTest` covers the rest, where they
  coincide and the anchor cannot be what makes an assertion pass.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Utils.DateTimeUtils

  @owner_timezone "Europe/Berlin"

  describe "an explicit interval anchors to the owner's clock" do
    test "a booker on a half-hour offset is offered the owner's boundaries, not their own" do
      date = ~D[2026-06-15]
      {start_dt, end_dt} = owner_window("Asia/Kolkata", date)

      slots = aligned_hourly_slots(start_dt, end_dt)

      # 09:00 in Berlin is 12:30 in Kolkata. Rounding forward on the booker's
      # clock would give 13:00, which is 09:30 on the owner's.
      assert List.first(slots) == "12:30 PM"

      assert Enum.reject(slots, &String.contains?(&1, ":30 ")) == [],
             "expected every start to keep the owner's phase, got: #{inspect(slots)}"
    end

    test "no slot is discarded: the offset booker is offered as many as the owner" do
      date = ~D[2026-06-15]
      {owner_start, owner_end} = owner_window(@owner_timezone, date)
      {booker_start, booker_end} = owner_window("Asia/Kathmandu", date)

      owner_slots = aligned_hourly_slots(owner_start, owner_end)
      booker_slots = aligned_hourly_slots(booker_start, booker_end)

      assert owner_slots == [
               "9:00 AM",
               "10:00 AM",
               "11:00 AM",
               "12:00 PM",
               "1:00 PM",
               "2:00 PM",
               "3:00 PM",
               "4:00 PM"
             ]

      # Rounding forward on the booker's clock would have thrown the owner's
      # first partial hour away, leaving seven.
      assert length(booker_slots) == length(owner_slots)
      assert List.first(booker_slots) == "12:45 PM"
    end

    test "the booker's timezone cannot move the grid" do
      date = ~D[2026-06-15]
      berlin = offered_on_owner_clock(@owner_timezone, date)

      assert berlin == [
               ~T[09:00:00],
               ~T[10:00:00],
               ~T[11:00:00],
               ~T[12:00:00],
               ~T[13:00:00],
               ~T[14:00:00],
               ~T[15:00:00],
               ~T[16:00:00]
             ]

      for booker_timezone <- ["Asia/Kolkata", "Asia/Kathmandu", "Australia/Eucla", "Etc/UTC"] do
        assert offered_on_owner_clock(booker_timezone, date) == berlin,
               "#{booker_timezone} was offered a different grid on the owner's clock"
      end
    end

    test "an owner-side spring forward keeps the grid on the owner's boundaries" do
      # Europe/Berlin springs forward at 02:00 CET -> 03:00 CEST on 2026-03-29,
      # so the owner's early window opens on a wall clock that skips an hour
      # while the booker's does not.
      date = ~D[2026-03-29]
      {start_dt, end_dt} = owner_window("Asia/Kolkata", date, ~T[01:30:00], ~T[06:00:00])

      slots = aligned_hourly_slots(start_dt, end_dt)

      # 01:30 CET rounds forward to 03:00 CEST, since 02:00 never happens, and
      # that is 06:30 in Kolkata.
      assert List.first(slots) == "6:30 AM"

      assert Enum.reject(slots, &String.contains?(&1, ":30 ")) == [],
             "expected every start to keep the owner's phase, got: #{inspect(slots)}"
    end

    # The anchor is consulted only for an explicit interval. A nil interval is
    # the duration-locked default rather than a choice the owner made, so it
    # must leave the grid exactly where the window opens, whatever anchor it is
    # handed. The window here opens off the hour, which is the only way to tell
    # "nil skips alignment" apart from "alignment happened to be a no-op", and
    # the anchor is deliberately a zone nobody involved is in.
    test "a nil interval never consults the anchor" do
      date = ~D[2026-06-15]
      start_dt = DateTime.new!(date, ~T[09:15:00], "America/New_York")
      end_dt = DateTime.new!(date, ~T[10:15:00], "America/New_York")

      with_foreign_anchor =
        TimeSlots.generate_slots_for_range_with_breaks(
          start_dt,
          end_dt,
          30,
          date,
          [],
          nil,
          "Asia/Kathmandu"
        )

      without_argument =
        TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [])

      assert with_foreign_anchor == without_argument
      assert List.first(with_foreign_anchor) == "9:15 AM"
    end
  end

  # The owner's window on `date`, shifted into the booker's timezone exactly as
  # the availability pipeline shifts it before generating slots.
  defp owner_window(booker_timezone, date, start_time \\ ~T[09:00:00], end_time \\ ~T[17:00:00]) do
    owner_start = DateTime.new!(date, start_time, @owner_timezone)
    owner_end = DateTime.new!(date, end_time, @owner_timezone)

    {:ok, start_dt} = DateTime.shift_zone(owner_start, booker_timezone)
    {:ok, end_dt} = DateTime.shift_zone(owner_end, booker_timezone)

    {start_dt, end_dt}
  end

  defp aligned_hourly_slots(start_dt, end_dt) do
    TimeSlots.generate_slots_for_range_with_breaks(
      start_dt,
      end_dt,
      60,
      DateTime.to_date(start_dt),
      [],
      60,
      @owner_timezone
    )
  end

  # The times a booker in `booker_timezone` is offered, read back on the
  # owner's clock: the grid every booker must agree on.
  defp offered_on_owner_clock(booker_timezone, date) do
    {start_dt, end_dt} = owner_window(booker_timezone, date)

    start_dt
    |> aligned_hourly_slots(end_dt)
    |> Enum.map(fn slot ->
      DateTime.to_time(
        DateTimeUtils.convert_to_timezone(
          DateTime.new!(
            DateTime.to_date(start_dt),
            TimeSlots.parse_time_slot(slot),
            booker_timezone
          ),
          @owner_timezone
        )
      )
    end)
  end
end
