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
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Utils.DateTimeUtils

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  describe "availability-display ↔ booking-validation invariant" do
    test "a slot shown as available can be booked successfully" do
      timezone = "Etc/UTC"
      %{user: user, schedule_id: schedule_id} = create_bookable_profile(timezone: timezone)
      target_date = next_bookable_weekday()

      TestMocks.stub_no_calendar_events()

      # Display path
      {:ok, slots} =
        Calculate.available_slots(target_date, 30, timezone, timezone, [], %{
          schedule_id: schedule_id
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
      %{user: user, schedule_id: schedule_id} = create_bookable_profile(timezone: timezone)
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
          schedule_id: schedule_id
        })

      assert slots_without_block != [],
             "expected at least one slot before the blocking event was introduced"

      # Display path with the blocking event — every slot must disappear.
      {:ok, slots_with_block} =
        Calculate.available_slots(target_date, 30, timezone, timezone, [blocking_event], %{
          schedule_id: schedule_id
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

  # A slot_interval_minutes narrower than the meeting's duration puts starts on
  # the offered grid that the duration-locked grid alone would never produce.
  # The invariant above only ever exercised the duration-locked grid; this
  # pins the same display↔booking agreement for the interval-only case.
  describe "availability-display ↔ booking-validation invariant, with a slot interval" do
    test "a start the interval makes legal is offered and can be booked, and an off-grid start is refused" do
      timezone = "Etc/UTC"

      # 09:00-10:15: a 60-minute meeting fits only one duration-locked start
      # (9:00). A 15-minute interval additionally legalises 9:15, which is
      # the case under test.
      %{user: user, schedule_id: schedule_id} =
        create_bookable_profile(
          timezone: timezone,
          hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[10:15:00]}
        )

      target_date = next_bookable_weekday()

      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: 15)

      TestMocks.stub_no_calendar_events()

      {:ok, duration_locked_slots} =
        Calculate.available_slots(target_date, 60, timezone, timezone, [], %{
          schedule_id: schedule_id
        })

      {:ok, interval_slots} =
        Calculate.available_slots(target_date, 60, timezone, timezone, [], %{
          schedule_id: schedule_id,
          slot_interval_minutes: 15
        })

      # The 9:15 start exists only because the interval was set — proving the
      # test actually exercises the interval path rather than a start the
      # duration-locked grid would have offered anyway.
      refute "9:15 AM" in duration_locked_slots
      assert "9:15 AM" in interval_slots

      form_data = %{
        "name" => "Interval Attendee",
        "email" => "interval-attendee@example.com",
        "message" => "Booking a time only the interval grid offers"
      }

      # 9:05 sits between two interval-grid starts (9:00 and 9:15) and is not
      # itself offered on either grid. Attempted BEFORE any booking exists, so
      # the refusal can only be grid-driven — after the 9:15 booking below it
      # would also overlap, and the assertion could not tell the two apart.
      refute "9:05 AM" in interval_slots

      assert {:error, :slot_taken} =
               Create.execute(
                 %{
                   date: target_date,
                   time: "9:05 AM",
                   duration: "60min",
                   user_timezone: timezone,
                   organizer_user_id: user.id,
                   meeting_type_id: meeting_type.id
                 },
                 form_data
               )

      assert {:ok, meeting} =
               Create.execute(
                 %{
                   date: target_date,
                   time: "9:15 AM",
                   duration: "60min",
                   user_timezone: timezone,
                   organizer_user_id: user.id,
                   meeting_type_id: meeting_type.id
                 },
                 form_data
               )

      assert meeting.status == "confirmed"
    end
  end

  # The interval is the host's setting, and it means "this far apart, on my
  # clock". A booker half an hour off the host's clock is the case that tells
  # that apart from "this far apart, on the booker's clock": the two anchor the
  # same window to different phases, and only one of them is the host's.
  describe "a slot interval anchors to the host's clock, not the booker's" do
    setup do
      TestMocks.stub_no_calendar_events()
      :ok
    end

    test "an offset booker is offered the host's boundaries, and only those can be booked" do
      host_timezone = "Europe/Berlin"
      # Kolkata is a permanent half hour off Berlin, on either side of either
      # zone's DST changeover, so the phase asserted below never moves.
      booker_timezone = "Asia/Kolkata"

      %{user: user, schedule_id: schedule_id} = create_bookable_profile(timezone: host_timezone)

      target_date = next_bookable_weekday()

      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: 60)

      config = %{schedule_id: schedule_id, slot_interval_minutes: 60}

      {:ok, host_slots} =
        Calculate.available_slots(target_date, 60, host_timezone, host_timezone, [], config)

      {:ok, booker_slots} =
        Calculate.available_slots(target_date, 60, booker_timezone, host_timezone, [], config)

      # The helper's window is 11:00-17:00, and the host's own grid sits on the
      # hour inside it.
      assert host_slots == [
               "11:00 AM",
               "12:00 PM",
               "1:00 PM",
               "2:00 PM",
               "3:00 PM",
               "4:00 PM"
             ]

      # Every start the booker is offered is half past the hour on their clock,
      # because it is on the hour on the host's.
      assert booker_slots != []

      assert Enum.reject(booker_slots, &String.contains?(&1, ":30 ")) == [],
             "expected every start to keep the host's phase, got: #{inspect(booker_slots)}"

      # Rounding forward on the booker's clock would also have discarded the
      # host's first hour.
      assert length(booker_slots) == length(host_slots)

      on_host_clock =
        Enum.map(booker_slots, fn slot ->
          target_date
          |> DateTime.new!(TimeSlots.parse_time_slot(slot), booker_timezone)
          |> DateTimeUtils.convert_to_timezone(host_timezone)
          |> DateTime.to_time()
        end)

      assert on_host_clock == Enum.map(host_slots, &TimeSlots.parse_time_slot/1)

      book = fn time ->
        Create.execute(
          %{
            date: target_date,
            time: time,
            duration: "60min",
            user_timezone: booker_timezone,
            organizer_user_id: user.id,
            meeting_type_id: meeting_type.id
          },
          %{
            "name" => "Offset Attendee",
            "email" => "offset-attendee@example.com",
            "message" => "Booking across a half-hour offset"
          }
        )
      end

      # The start the booker-anchored grid used to offer: the next whole hour
      # on their clock, which is half past on the host's.
      %Time{hour: first_hour, minute: 30} = TimeSlots.parse_time_slot(List.first(booker_slots))

      old_grid_start =
        TimeSlots.format_datetime_slot(
          DateTime.new!(target_date, Time.new!(first_hour + 1, 0, 0), booker_timezone)
        )

      refute old_grid_start in booker_slots
      assert {:error, :slot_taken} = book.(old_grid_start)

      assert {:ok, meeting} = book.(List.first(booker_slots))
      assert meeting.status == "confirmed"
    end
  end

  # The converse of the invariant above, and the reason it is enforced in the
  # domain rather than in the booking page's step machine: `/:username/:slug/book`
  # is directly enterable, so a booker can arrive at the submit path having
  # passed through none of the page's own guards. Only a check on the create
  # path itself can hold for those.
  describe "times the display never offered are refused by the booking API" do
    setup do
      TestMocks.stub_no_calendar_events()
      :ok
    end

    test "a time outside the host's working hours is refused" do
      timezone = "Etc/UTC"
      %{user: user, schedule_id: schedule_id} = create_bookable_profile(timezone: timezone)
      target_date = next_bookable_weekday()

      {:ok, slots} =
        Calculate.available_slots(target_date, 30, timezone, timezone, [], %{
          schedule_id: schedule_id
        })

      # The helper's window is 11:00–17:00, so 08:00 is a real time on a real
      # working day that the display simply never offers.
      refute "8:00 AM" in slots

      assert {:error, :slot_taken} =
               Create.execute(
                 booking_at(user, target_date, "08:00", "30min", timezone),
                 attendee()
               )
    end

    test "a day the host is not available at all is refused" do
      timezone = "Etc/UTC"

      %{user: user} = create_bookable_profile(timezone: timezone, days: [1, 2, 3])

      # A Thursday: inside the advance window, outside the host's Mon–Wed week.
      target_date = next_weekday_of(4)

      assert {:error, :slot_taken} =
               Create.execute(
                 booking_at(user, target_date, "12:00", "30min", timezone),
                 attendee()
               )
    end

    test "a duration that overruns the host's window is refused" do
      timezone = "Etc/UTC"
      %{user: user} = create_bookable_profile(timezone: timezone)
      target_date = next_bookable_weekday()

      # 11:00 starts inside the 11:00–17:00 window; nine hours does not fit in
      # it. Nothing else on the create path bounds a submitted duration.
      assert {:error, :slot_taken} =
               Create.execute(
                 booking_at(user, target_date, "11:00", "540min", timezone),
                 attendee()
               )
    end

    defp booking_at(user, date, time, duration, timezone) do
      %{
        date: date,
        time: time,
        duration: duration,
        user_timezone: timezone,
        organizer_user_id: user.id
      }
    end

    defp attendee do
      %{
        "name" => "Invariant Attendee",
        "email" => "invariant-attendee@example.com",
        "message" => "Attempting a time the schedule never offered"
      }
    end

    # The next date whose ISO weekday is `day_of_week`, at least ten days out so
    # the advance window never clips it.
    defp next_weekday_of(day_of_week) do
      Date.utc_today()
      |> Date.add(10)
      |> Stream.iterate(&Date.add(&1, 1))
      |> Enum.find(&(Date.day_of_week(&1) == day_of_week))
    end
  end
end
