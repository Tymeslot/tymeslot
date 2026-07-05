defmodule Tymeslot.Availability.DisplayBookingConsistencyTest do
  @moduledoc """
  Invariant tests asserting that the availability-display path and the
  booking-validation path agree.

  `Calculate.available_slots/6` (display) and `Validation.check_slot_availability/4`
  (booking) both rely on `CalendarEvent.blocking?/1` to decide whether a calendar
  event should prevent a slot from being offered/booked. Nothing in the type
  system keeps the two codepaths in sync, so these tests pin the end-to-end
  invariant: if the display shows a slot, the booking API must accept it; if
  the display hides a slot because a blocking event covers it, the booking API
  must reject attempts to book that time.

  These are the fixed-scenario anchors; `DisplayBookingConsistencyPropertyTest`
  fuzzes the same invariant across timezones, durations and event layouts.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  describe "availability-display ↔ booking-validation invariant" do
    test "a slot shown as available can be booked successfully" do
      timezone = "Etc/UTC"
      %{user: user, profile_id: profile_id} = create_bookable_profile(timezone: timezone)
      target_date = next_bookable_weekday()

      TestMocks.stub_no_calendar_events()

      # Display path
      {:ok, slots} =
        Calculate.available_slots(target_date, 30, timezone, timezone, [], %{
          profile_id: profile_id
        })

      # Sanity check: with no conflicts the weekday schedule should surface slots.
      assert slots != [], "expected at least one available slot on a weekday"

      chosen_slot = List.first(slots)

      meeting_params = %{
        date: target_date,
        time: chosen_slot,
        duration: "30min",
        user_timezone: timezone,
        organizer_user_id: user.id
      }

      form_data = %{
        "name" => "Invariant Attendee",
        "email" => "invariant-attendee@example.com",
        "message" => "Booking a slot the display said was available"
      }

      # Booking path
      assert {:ok, %MeetingSchema{} = meeting} = Create.execute(meeting_params, form_data)
      assert meeting.organizer_user_id == user.id
      assert meeting.status == "confirmed"
    end

    test "a slot hidden by a blocking event is rejected by the booking API" do
      timezone = "Etc/UTC"
      %{user: user, profile_id: profile_id} = create_bookable_profile(timezone: timezone)
      target_date = next_bookable_weekday()

      # The plain-map shape used by provider runtime adapters (Google, Outlook, CalDAV) —
      # this is what both the display and booking codepaths encounter in production.
      # Covers the entire working day so every offered slot on `target_date` is blocked.
      blocking_event = %{
        uid: "blocking-#{System.unique_integer([:positive])}",
        start_time: DateTime.new!(target_date, ~T[00:00:00], timezone),
        end_time: DateTime.new!(target_date, ~T[23:59:59], timezone),
        status: "confirmed",
        transparency: "opaque",
        summary: "All-day focus block"
      }

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok, [blocking_event]}
      end)

      # Display path without the blocking event — establishes the baseline set.
      {:ok, slots_without_block} =
        Calculate.available_slots(target_date, 30, timezone, timezone, [], %{
          profile_id: profile_id
        })

      assert slots_without_block != [],
             "expected at least one slot before the blocking event was introduced"

      # Display path with the blocking event — every slot must disappear.
      {:ok, slots_with_block} =
        Calculate.available_slots(target_date, 30, timezone, timezone, [blocking_event], %{
          profile_id: profile_id
        })

      assert slots_with_block == [],
             "expected all slots to be hidden by the blocking event, got: #{inspect(slots_with_block)}"

      # The diff is load-bearing: it proves the block actually caused the removal.
      blocked_slots = slots_without_block -- slots_with_block

      assert blocked_slots != [],
             "expected blocking event to hide at least one slot"

      # Booking path — each slot the display hid must be rejected by the booking API.
      Enum.each(blocked_slots, fn blocked_slot ->
        meeting_params = %{
          date: target_date,
          time: blocked_slot,
          duration: "30min",
          user_timezone: timezone,
          organizer_user_id: user.id
        }

        form_data = %{
          "name" => "Invariant Attendee",
          "email" => "invariant-attendee@example.com",
          "message" => "Attempting a time the display hid"
        }

        # The domain layer surfaces the semantic :slot_taken atom — the web
        # layer, not the domain layer, renders it to "no longer available"
        # display text.
        assert {:error, :slot_taken} = Create.execute(meeting_params, form_data)
      end)
    end
  end
end
