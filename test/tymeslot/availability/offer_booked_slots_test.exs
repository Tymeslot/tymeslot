defmodule Tymeslot.Availability.OfferBookedSlotsTest do
  @moduledoc """
  What the booking page offers once the host already has bookings.

  The page used to compute its offer from the host's connected calendars
  alone, so a booking blocked its own slot only through the provider event
  `CalendarEventWorker` mirrors it into. A host with no calendar connected
  therefore offered every slot they had already sold, for ever, and the submit
  refused each attempt on the meetings table. These tests pin the merged busy
  set that closes that gap: the host's own bookings block whether or not they
  have reached a calendar, the meeting being rescheduled still does not block
  itself, and nothing that has released its slot blocks at all.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  @timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} = create_bookable_profile(timezone: @timezone)

    %{user: user, profile: profile, date: next_bookable_weekday()}
  end

  describe "slots_for_date/3 with no calendar connected" do
    test "a confirmed booking withdraws its own slot", context do
      assert "11:00 AM" in slots(context)

      book(context, ~T[11:00:00])

      refute "11:00 AM" in slots(context)
    end

    test "a confirmed booking withdraws only the time it occupies", context do
      book(context, ~T[11:00:00])

      remaining = slots(context)

      # 12:00 is gone as well, to the host's buffer; the first start clear of
      # the booking and its buffer is 1:00, and the rest of the day stands.
      assert "1:00 PM" in remaining
      assert "4:00 PM" in remaining
    end

    test "a booking awaiting payment holds its slot, although it never reaches a calendar",
         context do
      # The calendar side effects of a paid booking are deferred until Stripe
      # confirms, so this status has no mirror to be blocked by even on a host
      # whose calendar works perfectly. It occupies the slot at the submit
      # (`MeetingState.where_slot_live/1`), so it has to occupy it here too.
      book(context, ~T[11:00:00], status: "awaiting_payment")

      refute "11:00 AM" in slots(context)
    end

    test "a booking awaiting the host's approval holds its slot", context do
      book(context, ~T[11:00:00], status: "awaiting_approval")

      refute "11:00 AM" in slots(context)
    end

    test "a cancelled booking gives its slot back", context do
      book(context, ~T[11:00:00], status: "cancelled")

      assert "11:00 AM" in slots(context)
    end

    test "a booking whose slot a reschedule request has voided gives it back", context do
      book(context, ~T[11:00:00], reschedule_requested_at: DateTime.utc_now(:second))

      assert "11:00 AM" in slots(context)
    end

    test "another host's booking does not withdraw this host's slot", context do
      %{user: other_user} = create_bookable_profile(timezone: @timezone)

      book(%{context | user: other_user}, ~T[11:00:00])

      assert "11:00 AM" in slots(context)
    end
  end

  describe "slots_for_date/3 when the booking has reached the calendar" do
    test "the slot is withdrawn once, leaving the rest of the day offered", context do
      meeting = book(context, ~T[11:00:00])
      stub_calendar_mirror(meeting)

      remaining = slots(context)

      refute "11:00 AM" in remaining
      assert "1:00 PM" in remaining
    end

    test "a mirror the host has marked free does not put the booked slot back on offer",
         context do
      # The mirror and the booking are one busy period described twice, and the
      # two can disagree: `CalendarEvent.blocking?/1` clears a transparent
      # event, so a host who marks their Tymeslot event "free" in Google would
      # otherwise have that copy decide. The submit locks the meeting, so the
      # meeting is what the page must answer from.
      meeting = book(context, ~T[11:00:00])
      stub_calendar_mirror(meeting, transparency: "transparent")

      refute "11:00 AM" in slots(context)
    end
  end

  describe "slots_for_date/3 on a reschedule page" do
    test "the booking being moved is still offered the time it occupies", context do
      meeting = book(context, ~T[11:00:00])

      refute "11:00 AM" in slots(context)
      assert "11:00 AM" in slots(context, meeting.uid)
    end

    test "the booking being moved is offered its own time although its mirror exists",
         context do
      meeting = book(context, ~T[11:00:00])
      stub_calendar_mirror(meeting)

      assert "11:00 AM" in slots(context, meeting.uid)
    end

    test "another booking still blocks the one being moved", context do
      meeting = book(context, ~T[11:00:00])
      book(context, ~T[15:00:00])

      offered = slots(context, meeting.uid)

      assert "11:00 AM" in offered
      refute "3:00 PM" in offered
    end
  end

  describe "days_in_range/4 with no calendar connected" do
    test "a day whose whole window is booked is no longer bookable", context do
      %{date: date} = context
      other_date = next_weekday_after(date)

      book(context, ~T[11:00:00], duration_minutes: 360)

      days = days(context, date, other_date)

      # Anchor: the following day is untouched, so `false` below is the booking
      # and not the schedule or the booking window.
      assert Map.fetch!(days, Date.to_iso8601(other_date))
      refute Map.fetch!(days, Date.to_iso8601(date))
    end

    test "a day with a booking and time left over stays bookable", context do
      %{date: date} = context

      book(context, ~T[11:00:00])

      assert Map.fetch!(days(context, date, date), Date.to_iso8601(date))
    end
  end

  describe "busy data reach for a day-long meeting" do
    test "a booking two days out blocks a day-long slot that would run into it" do
      # Host open around the clock in UTC; booker eleven hours behind. A 24-hour
      # meeting at 11:00 PM on `date` (Pago Pago) starts at 10:00 UTC the next
      # day and ends at 10:00 UTC the day after. The host's booking at 09:00 UTC
      # that day has to be in the busy set, or the slot is offered and then
      # refused at submit.
      host = around_the_clock_host()

      # An hourly grid makes 11:00 PM a candidate start for a 24-hour meeting.
      meeting_type =
        insert(:meeting_type, user: host.user, duration_minutes: 1440, slot_interval_minutes: 60)

      date = next_bookable_weekday()
      blocker_start = DateTime.new!(Date.add(date, 2), ~T[09:00:00], "Etc/UTC")

      insert(:meeting,
        organizer_user_id: host.user.id,
        start_time: blocker_start,
        end_time: DateTime.add(blocker_start, 30, :minute),
        duration: 30,
        status: "confirmed"
      )

      request = %{
        profile: host.profile,
        user_timezone: "Pacific/Pago_Pago",
        meeting_type: meeting_type
      }

      {:ok, slots} = Offer.slots_for_date(request, Date.to_iso8601(date), 1440)

      assert "10:00 AM" in slots,
             "the day must still offer something, or the refutation below proves nothing"

      refute "11:00 PM" in slots
    end

    test "a calendar event the day after the last bookable date withdraws a day-long slot, as the submit does" do
      # Host open around the clock in UTC, booked from a UTC page on the last
      # date the booking window reaches. A 24-hour meeting at midnight that day
      # ends at midnight the day after, and its fifteen-minute after-buffer
      # runs into an event at 00:05. The provider only returns events inside
      # the range it is asked for, so the page has to ask past the window's
      # last date or it offers a slot the submit, which reads the slot's own
      # range, then refuses.
      host = around_the_clock_host()
      last_date = Date.add(Date.utc_today(), host.schedule.advance_booking_days)
      event_start = DateTime.new!(Date.add(last_date, 1), ~T[00:05:00], "Etc/UTC")

      AvailabilityCache.clear_all()

      assert "12:00 AM" in offered(host.profile, last_date, 1440),
             "without the event the slot is on offer, or the refutation below proves nothing"

      stub_ranged_calendar([
        %{
          uid: "evening-after",
          start_time: event_start,
          end_time: DateTime.add(event_start, 60, :minute),
          status: "confirmed",
          transparency: "opaque",
          summary: "Busy"
        }
      ])

      AvailabilityCache.clear_all()
      refute "12:00 AM" in offered(host.profile, last_date, 1440)

      assert {:error, :slot_taken} =
               Create.execute(
                 %{
                   date: last_date,
                   time: "12:00 AM",
                   duration: "1440min",
                   user_timezone: "Etc/UTC",
                   organizer_user_id: host.user.id,
                   meeting_type_id: nil
                 },
                 %{"name" => "Late", "email" => "late@example.com", "message" => ""}
               )
    end
  end

  defp around_the_clock_host do
    create_bookable_profile(
      timezone: "Etc/UTC",
      days: Enum.to_list(1..7),
      hours: %{
        is_available: true,
        start_time: ~T[00:00:00],
        end_time: ~T[00:00:00],
        ends_next_day: true
      }
    )
  end

  # A provider answers for the range it is asked about and nothing else.
  defp stub_ranged_calendar(events) do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
      {:ok,
       Enum.filter(events, fn event ->
         Date.compare(DateTime.to_date(event.start_time), end_date) != :gt and
           Date.compare(DateTime.to_date(event.end_time), start_date) != :lt
       end)}
    end)
  end

  defp next_weekday_after(date) do
    next = Date.add(date, 1)

    if Date.day_of_week(next) in 1..5, do: next, else: next_weekday_after(next)
  end

  defp request(%{profile: profile}, reschedule_uid) do
    %{profile: profile, user_timezone: @timezone, reschedule_uid: reschedule_uid}
  end

  defp slots(context, reschedule_uid \\ nil) do
    AvailabilityCache.clear_all()

    {:ok, slots} =
      context
      |> request(reschedule_uid)
      |> Offer.slots_for_date(Date.to_iso8601(context.date), 60)

    slots
  end

  defp days(context, start_date, end_date) do
    AvailabilityCache.clear_all()

    {:ok, days} =
      context
      |> request(nil)
      |> Offer.days_in_range(start_date, end_date, 60)

    days
  end

  defp book(%{user: user, date: date}, time, attrs \\ []) do
    duration_minutes = Keyword.get(attrs, :duration_minutes, 60)
    start_time = DateTime.new!(date, time, @timezone)

    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: user.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, duration_minutes, :minute),
          duration: duration_minutes
        ],
        Keyword.drop(attrs, [:duration_minutes])
      )
    )
  end

  # The booking as it comes back from the host's calendar: same times, and the
  # identifier `Tymeslot.Meetings.CalendarEventLink` matches the two sides on.
  defp stub_calendar_mirror(meeting, opts \\ []) do
    event = %{
      uid: meeting.calendar_uid,
      provider_event_id: meeting.provider_event_id,
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      status: "confirmed",
      transparency: Keyword.get(opts, :transparency, "opaque"),
      summary: meeting.title
    }

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start_date, _end_date ->
      {:ok, [event]}
    end)
  end
end
