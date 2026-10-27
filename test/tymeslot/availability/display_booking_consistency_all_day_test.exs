defmodule Tymeslot.Availability.DisplayBookingConsistencyAllDayTest do
  @moduledoc """
  The display and the submit-time calendar check must place an all-day event
  on the same stretch of time: the host's local day.

  Companion to `DisplayBookingConsistencyTest`, split out to keep that module
  under the size limit. A host far from UTC exposes any path that anchors the
  event's dates at UTC midnight instead: Sydney's morning is the previous UTC
  day, so such a path refuses the morning after the event, which the booking
  page offers, and lets through the morning of the event itself.

  The calendar stub answers only for the range it is asked about, as a
  provider does, so a fetch whose range misses the host's local day misses
  the event too.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{CalendarCheck, Create}
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()

    holiday = Date.add(Date.utc_today(), 10)

    stub_calendar([
      %{
        uid: "holiday-#{System.unique_integer([:positive])}",
        start_time: holiday,
        end_time: Date.add(holiday, 1),
        all_day: true,
        status: "confirmed",
        transparency: "opaque",
        summary: "Public holiday"
      }
    ])

    %{holiday: holiday}
  end

  describe "a host in Sydney" do
    setup :host_in_sydney

    test "the morning after an all-day event is offered and accepted", ctx do
      %{user: user, profile: profile, meeting_type: meeting_type, holiday: holiday} = ctx
      day_after = Date.add(holiday, 1)
      config = Schedules.booking_config(user.id, meeting_type)

      # 09:00 and 10:00 in Sydney are still the holiday's date in UTC.
      for time <- ["9:00 AM", "10:00 AM"] do
        assert time in offered(profile, day_after, "30min", meeting_type: meeting_type)
        assert CalendarCheck.probe(slot(user, day_after, time, ctx.timezone), config) == :ok
      end

      assert {:ok, %MeetingSchema{status: "confirmed"}} =
               book_at(ctx, day_after, "9:00 AM")
    end

    test "the morning of an all-day event is hidden and refused", ctx do
      %{user: user, profile: profile, meeting_type: meeting_type, holiday: holiday} = ctx
      config = Schedules.booking_config(user.id, meeting_type)

      assert offered(profile, holiday, "30min", meeting_type: meeting_type) == []

      for time <- ["9:00 AM", "10:00 AM"] do
        assert CalendarCheck.probe(slot(user, holiday, time, ctx.timezone), config) ==
                 {:error, :slot_unavailable}
      end

      assert {:error, :slot_taken} = book_at(ctx, holiday, "9:00 AM")
    end
  end

  # A provider can send an event with no end. Both paths read it the same
  # way: a date-only one blocks the host's day, a timed one thirty minutes.
  describe "an event without an end" do
    setup :host_in_sydney

    test "an all-day one hides the host's day and the submit refuses it", ctx do
      %{user: user, profile: profile, meeting_type: meeting_type, holiday: holiday} = ctx
      config = Schedules.booking_config(user.id, meeting_type)
      stub_calendar([no_end_event(holiday, all_day: true)])

      assert offered(profile, holiday, "30min", meeting_type: meeting_type) == []

      assert CalendarCheck.probe(slot(user, holiday, "9:00 AM", ctx.timezone), config) ==
               {:error, :slot_unavailable}

      assert {:error, :slot_taken} = book_at(ctx, holiday, "9:00 AM")

      assert "9:00 AM" in offered(profile, Date.add(holiday, 1), "30min",
               meeting_type: meeting_type
             )
    end

    test "a timed one blocks thirty minutes on both paths", ctx do
      %{user: user, profile: profile, meeting_type: meeting_type, holiday: day} = ctx
      config = Schedules.booking_config(user.id, meeting_type)

      stub_calendar([
        no_end_event(DateTime.new!(day, ~T[10:00:00], ctx.timezone), all_day: false)
      ])

      offered = offered(profile, day, "30min", meeting_type: meeting_type)

      # Hidden at its start, offered again soon after: a block of thirty
      # minutes (plus the buffers), not a dropped event and not a whole day.
      refute "10:00 AM" in offered
      assert "11:00 AM" in offered

      for time <- ["9:00 AM", "9:30 AM", "10:00 AM", "10:30 AM", "11:00 AM"] do
        expected = if time in offered, do: :ok, else: {:error, :slot_unavailable}
        assert CalendarCheck.probe(slot(user, day, time, ctx.timezone), config) == expected
      end
    end
  end

  # A booking submitted from a page drawn before the host added the event, or
  # a reschedule onto that day, is refused by the submit-time re-read alone.
  # These hosts' local day sits wholly or partly in a neighbouring UTC day, so
  # the re-read must ask the calendar about more than the slot's UTC date.
  for {timezone, time, utc_day} <- [
        {"Pacific/Kiritimati", "9:00 AM", "the day before"},
        {"Pacific/Honolulu", "3:00 PM", "the day after"}
      ] do
    describe "a host in #{timezone}" do
      setup ctx, do: host_in(ctx, unquote(timezone))

      test "a stale page cannot book #{time} on the all-day event (#{utc_day} in UTC)", ctx do
        %{user: user, meeting_type: meeting_type, holiday: holiday} = ctx
        config = Schedules.booking_config(user.id, meeting_type)

        assert CalendarCheck.probe(slot(user, holiday, unquote(time), ctx.timezone), config) ==
                 {:error, :slot_unavailable}

        assert {:error, :slot_taken} = book_at(ctx, holiday, unquote(time))
        assert Repo.aggregate(MeetingSchema, :count) == 0
      end
    end
  end

  defp host_in_sydney(ctx), do: host_in(ctx, "Australia/Sydney")

  defp host_in(_ctx, timezone) do
    %{user: user, profile: profile} = create_always_bookable_profile(timezone: timezone)
    meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

    %{user: user, profile: profile, meeting_type: meeting_type, timezone: timezone}
  end

  defp no_end_event(start, all_day: all_day) do
    %{
      uid: "no-end-#{System.unique_integer([:positive])}",
      start_time: start,
      end_time: nil,
      all_day: all_day,
      status: "confirmed",
      transparency: "opaque",
      summary: "No end"
    }
  end

  # Returns only the events overlapping the requested UTC days, reading an
  # all-day event's dates as UTC days: a fetch that asks about too narrow a
  # range gets nothing back, which the submit-time re-read must survive.
  defp stub_calendar(events) do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
      range_start = utc_instant(start_date)
      range_end = end_date |> Date.add(1) |> utc_instant()

      {:ok,
       Enum.filter(events, fn event ->
         starts = utc_instant(event.start_time)

         DateTime.compare(starts, range_end) == :lt and
           DateTime.compare(ends_at(event, starts), range_start) == :gt
       end)}
    end)
  end

  # An event without an end is read as the instant it starts.
  defp ends_at(%{end_time: nil}, starts), do: DateTime.add(starts, 1, :second)
  defp ends_at(%{end_time: end_time}, _starts), do: utc_instant(end_time)

  defp utc_instant(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp utc_instant(%DateTime{} = datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")

  defp slot(user, date, time, timezone) do
    start = DateTime.new!(date, TimeSlots.parse_time_slot(time), timezone)

    %{
      organizer_user_id: user.id,
      start_datetime: start,
      end_datetime: DateTime.add(start, 30, :minute)
    }
  end

  defp book_at(%{user: user, meeting_type: meeting_type, timezone: timezone}, date, time) do
    Create.execute(
      %{
        date: date,
        time: time,
        duration: "30min",
        user_timezone: timezone,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      },
      %{
        "name" => "Holiday Attendee",
        "email" => "holiday-#{System.unique_integer([:positive])}@example.com",
        "message" => "Booking around a public holiday"
      }
    )
  end
end
