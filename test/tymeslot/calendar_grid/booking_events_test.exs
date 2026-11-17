defmodule Tymeslot.CalendarGrid.BookingEventsTest do
  @moduledoc """
  Covers the booking-to-grid-event projection: which bookings load for a
  window and how they are shaped for the grid. A booking's calendar copy is
  dropped in its favour by `EventWindow` (see `EventWindowTest`).
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.BookingEvent

  defp window do
    start_dt = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    {start_dt, DateTime.add(start_dt, 7 * 86_400, :second)}
  end

  defp insert_meeting(user, attrs) do
    # Distinct start times per insert: the schema enforces one confirmed
    # meeting per organiser per start time.
    offset = Process.get(:booking_start_offset, 0)
    Process.put(:booking_start_offset, offset + 1)

    midnight = DateTime.new!(Date.add(Date.utc_today(), 1), ~T[00:00:00], "Etc/UTC")
    start_time = DateTime.add(midnight, offset * 60, :second)

    defaults = %{
      organizer_user: user,
      start_time: start_time,
      end_time: DateTime.add(start_time, 1800, :second),
      status: :confirmed
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  test "names nobody under a meeting the host manages" do
    user = insert(:user)

    # The attendee fields hold the first guest, who booked nothing.
    insert_meeting(user, %{
      title: "Quarterly planning",
      attendee_name: "ada@example.com",
      attendee_email: "ada@example.com",
      managed_by_host: true
    })

    {start_dt, end_dt} = window()

    assert [%BookingEvent{summary: "Quarterly planning", attendee_name: nil, attendee_email: nil}] =
             CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt)
  end

  test "projects a live booking into the grid event shape" do
    user = insert(:user)

    meeting =
      insert_meeting(user, %{
        title: "Discovery call",
        attendee_name: "Ada Lovelace",
        location: "Video call"
      })

    {start_dt, end_dt} = window()

    assert [%BookingEvent{} = event] =
             CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt)

    assert event.id == "booking-#{meeting.id}"
    assert event.meeting_id == meeting.id
    assert event.uid == meeting.calendar_uid
    refute event.uid == meeting.uid
    assert event.summary == "Discovery call"
    assert event.attendee_name == "Ada Lovelace"
    assert event.location == "Video call"
    assert event.start_at == meeting.start_time
    assert event.end_at == meeting.end_time
    assert event.all_day == false
    assert event.created_by_tymeslot
    assert event.kind == :booking
  end

  test "excludes cancelled bookings and slots voided by a reschedule request" do
    user = insert(:user)
    insert_meeting(user, %{status: :cancelled})
    insert_meeting(user, %{reschedule_requested_at: DateTime.utc_now()})

    {start_dt, end_dt} = window()

    assert CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt) == []
  end

  test "includes past bookings inside the window and excludes out-of-window ones" do
    user = insert(:user)

    past_start = DateTime.new!(Date.utc_today(), ~T[01:00:00], "Etc/UTC")

    past =
      insert_meeting(user, %{
        title: "Earlier today",
        start_time: past_start,
        end_time: DateTime.add(past_start, 1800, :second)
      })

    far_start = DateTime.new!(Date.add(Date.utc_today(), 30), ~T[09:00:00], "Etc/UTC")

    insert_meeting(user, %{
      title: "Far future",
      start_time: far_start,
      end_time: DateTime.add(far_start, 3600, :second)
    })

    {start_dt, end_dt} = window()

    assert [event] = CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt)
    assert event.meeting_id == past.id
  end

  test "does not return other organisers' bookings" do
    user = insert(:user)
    other = insert(:user)
    insert_meeting(other, %{title: "Someone else's"})

    {start_dt, end_dt} = window()

    assert CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt) == []
  end

  test "falls back to a generic title when the booking title is blank" do
    user = insert(:user)
    insert_meeting(user, %{title: "   "})

    {start_dt, end_dt} = window()

    assert [%{summary: "Meeting"}] =
             CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt)
  end

  describe "requests and meeting types" do
    test "carries the meeting type, whether it is a request, and its deadline" do
      user = insert(:user)
      deadline = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      insert_meeting(user, %{
        status: "awaiting_approval",
        meeting_type: "Intro call",
        approval_requested_at: DateTime.utc_now(:second),
        approval_deadline_at: deadline
      })

      {start_dt, end_dt} = window()

      assert [event] = CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt)
      assert event.meeting_type == "Intro call"
      assert event.request == true
      assert event.expired == false
      assert event.approval_deadline_at == deadline
    end

    test "a request held past its deadline is expired, though the sweep has not reached it" do
      user = insert(:user)

      insert_meeting(user, %{
        status: "awaiting_approval",
        approval_requested_at: DateTime.add(DateTime.utc_now(:second), -7200, :second),
        approval_deadline_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      })

      {start_dt, end_dt} = window()

      assert [%BookingEvent{request: true, expired: true}] =
               CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt)
    end

    test "a request whose start has passed is expired though its deadline is ahead" do
      user = insert(:user)
      now = DateTime.utc_now(:second)
      start_time = DateTime.add(now, -600, :second)

      insert_meeting(user, %{
        status: "awaiting_approval",
        start_time: start_time,
        end_time: DateTime.add(start_time, 1800, :second),
        approval_requested_at: DateTime.add(now, -7200, :second),
        approval_deadline_at: DateTime.add(now, 3600, :second)
      })

      from = DateTime.add(now, -86_400, :second)
      to = DateTime.add(now, 86_400, :second)

      assert [%BookingEvent{request: true, expired: true}] =
               CalendarGrid.list_booking_events_for_range(user.id, from, to)
    end

    test "expired requests of another organiser or outside the window are not loaded" do
      user = insert(:user)
      other = insert(:user)
      now = DateTime.utc_now(:second)

      expired = fn organiser, offset_days ->
        start_time =
          DateTime.add(
            DateTime.new!(Date.utc_today(), ~T[12:00:00], "Etc/UTC"),
            offset_days * 86_400,
            :second
          )

        insert_meeting(organiser, %{
          status: "expired",
          start_time: start_time,
          end_time: DateTime.add(start_time, 1800, :second),
          approval_requested_at: DateTime.add(now, -7200, :second),
          approval_resolved_at: DateTime.add(now, -30, :second),
          cancelled_at: DateTime.add(now, -30, :second)
        })
      end

      mine = expired.(user, 1)
      expired.(other, 1)
      expired.(user, 30)

      {start_dt, end_dt} = window()

      assert [%BookingEvent{meeting_id: id}] =
               CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt,
                 include_expired: true
               )

      assert id == mine.id
    end

    test "a confirmed booking is neither a request nor expired" do
      user = insert(:user)
      insert_meeting(user, %{meeting_type: "  "})

      {start_dt, end_dt} = window()

      assert [%BookingEvent{request: false, expired: false, meeting_type: nil, copy: nil}] =
               CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt)
    end

    test "requests that expired unanswered load only when asked for, abandoned checkouts never" do
      user = insert(:user)
      now = DateTime.utc_now(:second)

      lapsed =
        insert_meeting(user, %{
          status: "expired",
          title: "Lapsed request",
          approval_requested_at: DateTime.add(now, -7200, :second),
          approval_deadline_at: DateTime.add(now, -60, :second),
          approval_resolved_at: DateTime.add(now, -30, :second),
          cancelled_at: DateTime.add(now, -30, :second)
        })

      insert_meeting(user, %{status: "expired", title: "Abandoned checkout"})

      {start_dt, end_dt} = window()

      assert CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt) == []

      assert [%BookingEvent{request: false, expired: true} = event] =
               CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt,
                 include_expired: true
               )

      assert event.meeting_id == lapsed.id
    end
  end
end
