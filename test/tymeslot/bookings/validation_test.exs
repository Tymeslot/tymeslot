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

    test "ignores TRANSP:TRANSPARENT events (free/busy = free)" do
      events = [
        %{
          start_time: ~U[2026-04-07 10:00:00Z],
          end_time: ~U[2026-04-07 11:00:00Z],
          status: "confirmed",
          transparency: "transparent"
        }
      ]

      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-07 10:30:00Z],
                 ~U[2026-04-07 11:30:00Z],
                 events,
                 0
               )
    end

    test "ignores cancelled events" do
      events = [
        %{
          start_time: ~U[2026-04-07 10:00:00Z],
          end_time: ~U[2026-04-07 11:00:00Z],
          status: "cancelled",
          transparency: "opaque"
        }
      ]

      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-07 10:30:00Z],
                 ~U[2026-04-07 11:30:00Z],
                 events,
                 0
               )
    end

    test "ignores declined events" do
      events = [
        %{
          start_time: ~U[2026-04-07 10:00:00Z],
          end_time: ~U[2026-04-07 11:00:00Z],
          status: "declined",
          transparency: "opaque"
        }
      ]

      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-07 10:30:00Z],
                 ~U[2026-04-07 11:30:00Z],
                 events,
                 0
               )
    end

    test "ignores all-day transparent events spanning multiple days" do
      # Regression: a TRANSP:TRANSPARENT vacation spanning two weeks was
      # blocking every booking on every day during the vacation, even though
      # the display path correctly showed slots as available.
      events = [
        %{
          start_time: ~D[2026-04-22],
          end_time: ~D[2026-05-06],
          status: "confirmed",
          transparency: "transparent"
        }
      ]

      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-29 14:00:00Z],
                 ~U[2026-04-29 15:00:00Z],
                 events,
                 15
               )
    end

    test "still blocks opaque all-day events (normal vacation)" do
      events = [
        %{
          start_time: ~D[2026-04-22],
          end_time: ~D[2026-05-06],
          status: "confirmed",
          transparency: "opaque"
        }
      ]

      assert {:error, :slot_unavailable} =
               Validation.check_slot_availability(
                 ~U[2026-04-29 14:00:00Z],
                 ~U[2026-04-29 15:00:00Z],
                 events,
                 0
               )
    end

    test "filters transparent events while keeping blocking ones in a mixed list" do
      events = [
        %{
          start_time: ~U[2026-04-07 09:00:00Z],
          end_time: ~U[2026-04-07 10:00:00Z],
          status: "confirmed",
          transparency: "transparent"
        },
        %{
          start_time: ~U[2026-04-07 14:00:00Z],
          end_time: ~U[2026-04-07 15:00:00Z],
          status: "confirmed",
          transparency: "opaque"
        }
      ]

      # 10:30 slot is clear — the 9-10 transparent event doesn't block
      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-07 10:30:00Z],
                 ~U[2026-04-07 11:00:00Z],
                 events,
                 0
               )

      # 14:30 slot overlaps the opaque event — still blocked
      assert {:error, :slot_unavailable} =
               Validation.check_slot_availability(
                 ~U[2026-04-07 14:30:00Z],
                 ~U[2026-04-07 15:30:00Z],
                 events,
                 0
               )
    end

    test "accepts %CalendarEvent{} structs with atom-valued status and transparency" do
      alias Tymeslot.Integrations.Calendar.CalendarEvent

      transparent_event = %CalendarEvent{
        uid: "vacation-1",
        calendar_integration_id: 1,
        provider: :caldav,
        provider_calendar_id: "cal-1",
        all_day: false,
        synced_at: ~U[2026-04-01 00:00:00Z],
        start_at: ~U[2026-04-07 10:00:00Z],
        end_at: ~U[2026-04-07 11:00:00Z],
        status: :confirmed,
        transparency: :transparent
      }

      # Struct path: blocking?/1 checks :transparency == :transparent
      # The struct's start_at/end_at aren't under :start_time, but the filter
      # happens before normalisation — so a transparent struct is dropped
      # regardless of its timing field names.
      assert :ok =
               Validation.check_slot_availability(
                 ~U[2026-04-07 10:30:00Z],
                 ~U[2026-04-07 11:30:00Z],
                 [transparent_event],
                 0
               )
    end
  end

  describe "parse_meeting_times/4 with DST-ambiguous or nonexistent wall-clock times" do
    # Europe/Berlin: clocks fall back from CEST to CET at 03:00 -> 02:00 on
    # this date, so 02:30 occurs twice (once at +02:00, once at +01:00).
    test "resolves an ambiguous autumn DST fallback time to the earlier instant" do
      assert {:ok, {start_datetime, _end_datetime}} =
               Validation.parse_meeting_times("2025-10-26", "02:30", 30, "Europe/Berlin")

      {:ambiguous, earlier, _later} =
        DateTime.new(~D[2025-10-26], ~T[02:30:00], "Europe/Berlin")

      assert DateTime.compare(start_datetime, earlier) == :eq
      # Earlier occurrence is still on CEST (+02:00), the later one on CET (+01:00).
      assert start_datetime.utc_offset + start_datetime.std_offset == 7200
    end

    # Europe/Berlin: clocks spring forward from CET to CEST at 02:00 -> 03:00
    # on this date, so 02:30 never occurs.
    test "resolves a spring DST gap time to the instant just after the gap" do
      assert {:ok, {start_datetime, _end_datetime}} =
               Validation.parse_meeting_times("2025-03-30", "02:30", 30, "Europe/Berlin")

      assert DateTime.compare(start_datetime, ~U[2025-03-30 01:00:00Z]) == :eq
    end

    test "still succeeds for a normal, unambiguous time" do
      assert {:ok, {start_datetime, end_datetime}} =
               Validation.parse_meeting_times("2025-06-15", "10:00", 30, "Europe/Berlin")

      assert DateTime.compare(
               start_datetime,
               DateTime.new!(~D[2025-06-15], ~T[10:00:00], "Europe/Berlin")
             ) == :eq

      assert DateTime.diff(end_datetime, start_datetime, :minute) == 30
    end

    test "still rejects an unknown timezone" do
      assert {:error, "Invalid date or time format"} =
               Validation.parse_meeting_times("2025-06-15", "10:00", 30, "Not/AZone")
    end
  end
end
