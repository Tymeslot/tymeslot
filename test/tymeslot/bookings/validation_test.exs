defmodule Tymeslot.Bookings.ValidationTest do
  @moduledoc """
  Tests for Tymeslot.Bookings.Validation, focusing on edge cases
  around calendar event normalization during conflict checking.
  """
  use ExUnit.Case, async: true
  @moduletag :bookings

  alias Tymeslot.Bookings.Validation

  describe "check_slot_availability/4" do
    test "detects conflict with a normal DateTime event" do
      events = [
        %{start_time: ~U[2026-04-07 10:00:00Z], end_time: ~U[2026-04-07 11:00:00Z]}
      ]

      assert {:error, :slot_unavailable} =
               Validation.check_slot_availability(
                 ~U[2026-04-07 10:30:00Z],
                 ~U[2026-04-07 11:30:00Z],
                 events,
                 0
               )
    end

    test "returns :ok when no conflict exists" do
      events = [
        %{start_time: ~U[2026-04-07 10:00:00Z], end_time: ~U[2026-04-07 11:00:00Z]}
      ]

      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-07 12:00:00Z],
                 ~U[2026-04-07 13:00:00Z],
                 events,
                 0
               )
    end

    test "handles all-day events with Date start_time and end_time" do
      events = [
        %{start_time: ~D[2026-04-07], end_time: ~D[2026-04-08]}
      ]

      # An all-day event spanning April 7 should conflict with a slot on April 7
      assert {:error, :slot_unavailable} =
               Validation.check_slot_availability(
                 ~U[2026-04-07 10:00:00Z],
                 ~U[2026-04-07 11:00:00Z],
                 events,
                 0
               )
    end

    test "handles all-day events with Date start_time and nil end_time" do
      events = [
        %{start_time: ~D[2026-04-07], end_time: nil}
      ]

      # nil end_time should be normalised to start + 30 minutes (00:00 to 00:30 UTC)
      assert {:error, :slot_unavailable} =
               Validation.check_slot_availability(
                 ~U[2026-04-07 00:15:00Z],
                 ~U[2026-04-07 00:45:00Z],
                 events,
                 0
               )
    end

    test "all-day event does not conflict with slot on a different day" do
      events = [
        %{start_time: ~D[2026-04-07], end_time: ~D[2026-04-08]}
      ]

      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-08 10:00:00Z],
                 ~U[2026-04-08 11:00:00Z],
                 events,
                 0
               )
    end

    test "handles mixed DateTime and Date events in the same list" do
      events = [
        %{start_time: ~D[2026-04-07], end_time: ~D[2026-04-08]},
        %{start_time: ~U[2026-04-07 14:00:00Z], end_time: ~U[2026-04-07 15:00:00Z]}
      ]

      # Conflicts with the DateTime event
      assert {:error, :slot_unavailable} =
               Validation.check_slot_availability(
                 ~U[2026-04-07 14:30:00Z],
                 ~U[2026-04-07 15:30:00Z],
                 events,
                 0
               )
    end

    test "buffer is applied correctly with Date events" do
      events = [
        %{start_time: ~D[2026-04-07], end_time: ~D[2026-04-08]}
      ]

      # All-day event: 00:00 to 00:00 next day. With 15min buffer: 23:45 Apr 6 to 00:15 Apr 8.
      # Slot at 23:50 on Apr 6 should now conflict due to buffer.
      assert {:error, :slot_unavailable} =
               Validation.check_slot_availability(
                 ~U[2026-04-06 23:50:00Z],
                 ~U[2026-04-07 00:20:00Z],
                 events,
                 15
               )
    end
  end
end
