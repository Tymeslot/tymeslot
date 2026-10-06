defmodule Tymeslot.Availability.TimeSlotsOwnerAnchorTest do
  @moduledoc """
  Tests for the clock an explicit slot interval anchors its grid to.

  Slots are listed on the booker's clock, but the interval is the owner's
  setting and means "this far apart, on my clock", so alignment reads the
  owner's timezone. These cases are the ones where the two clocks differ;
  `Tymeslot.Availability.TimeSlotsTest` covers the rest, where they coincide
  and the anchor cannot be what makes an assertion pass.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Utils.DateTimeUtils

  @owner_timezone "Europe/Berlin"
  # 2026-06-15 is a Monday.
  @monday ~D[2026-06-15]

  describe "an explicit interval anchors to the owner's clock" do
    test "a booker on a half-hour offset is offered the owner's boundaries, not their own" do
      slots = hourly_slots("Asia/Kolkata", @monday)

      # 09:00 in Berlin is 12:30 in Kolkata. Rounding forward on the booker's
      # clock would give 13:00, which is 09:30 on the owner's.
      assert List.first(slots) == "12:30 PM"

      assert Enum.reject(slots, &String.contains?(&1, ":30 ")) == [],
             "expected every start to keep the owner's phase, got: #{inspect(slots)}"
    end

    test "no slot is discarded: the offset booker is offered as many as the owner" do
      owner_slots = hourly_slots(@owner_timezone, @monday)
      booker_slots = hourly_slots("Asia/Kathmandu", @monday)

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
      berlin = offered_on_owner_clock(@owner_timezone, @monday)

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
        assert offered_on_owner_clock(booker_timezone, @monday) == berlin,
               "#{booker_timezone} was offered a different grid on the owner's clock"
      end
    end

    test "an owner-side spring forward keeps the grid on the owner's boundaries" do
      # Europe/Berlin springs forward at 02:00 CET -> 03:00 CEST on 2026-03-29
      # (a Sunday), so the owner's early window opens on a wall clock that
      # skips an hour while the booker's does not.
      slots =
        hourly_slots("Asia/Kolkata", ~D[2026-03-29], ~T[01:30:00], ~T[06:00:00])

      # 01:30 CET rounds forward to 03:00 CEST, since 02:00 never happens, and
      # that is 06:30 in Kolkata.
      assert List.first(slots) == "6:30 AM"

      assert Enum.reject(slots, &String.contains?(&1, ":30 ")) == [],
             "expected every start to keep the owner's phase, got: #{inspect(slots)}"
    end

    # A nil interval is the duration-locked default rather than a choice the
    # owner made, so it must leave the grid exactly where the window opens,
    # whatever the booker's zone. The window here opens off the hour, which is
    # the only way to tell "nil skips alignment" apart from "alignment happened
    # to be a no-op"; the explicit interval beside it does align.
    test "a nil interval leaves the grid where the window opens, whatever the booker's zone" do
      config = owner_config(@monday, ~T[09:15:00], ~T[10:15:00], nil)

      assert labels(@monday, 30, "America/New_York", "America/New_York", config) ==
               ["9:15 AM", "9:45 AM"]

      # 09:15 EDT is 13:15 UTC, which is 19:00 in Kathmandu (+05:45).
      assert labels(@monday, 30, "America/New_York", "Asia/Kathmandu", config) ==
               ["7:00 PM", "7:30 PM"]

      aligned = owner_config(@monday, ~T[09:15:00], ~T[10:15:00], 30)

      assert labels(@monday, 30, "America/New_York", "America/New_York", aligned) ==
               ["9:30 AM"]
    end
  end

  # The owner's schedule: one window on the weekday of `date`, with an
  # explicit interval of `interval` minutes (or the duration-locked default).
  defp owner_config(date, start_time, end_time, interval) do
    pure_config(
      days: [
        %{day_of_week: Date.day_of_week(date), start_time: start_time, end_time: end_time}
      ],
      interval: interval
    )
  end

  # What a booker in `booker_timezone` is offered for a 60-minute meeting on an
  # hourly grid, for the owner's window on `date`.
  defp hourly_slots(booker_timezone, date, start_time \\ ~T[09:00:00], end_time \\ ~T[17:00:00]) do
    config = owner_config(date, start_time, end_time, 60)
    labels(date, 60, @owner_timezone, booker_timezone, config)
  end

  # The times a booker in `booker_timezone` is offered, read back on the
  # owner's clock: the grid every booker must agree on.
  defp offered_on_owner_clock(booker_timezone, date) do
    booker_timezone
    |> hourly_slots(date)
    |> Enum.map(fn slot ->
      date
      |> DateTime.new!(TimeSlots.parse_time_slot(slot), booker_timezone)
      |> DateTimeUtils.convert_to_timezone(@owner_timezone)
      |> DateTime.to_time()
    end)
  end
end
