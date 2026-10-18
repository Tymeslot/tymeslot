defmodule Tymeslot.CalendarGrid.BookingEventsTest do
  @moduledoc """
  Covers the booking-to-grid-event projection: which bookings load for a
  window, how they are shaped for the grid, and deduplication against
  provider-synced copies.
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

  defp cached_event(attrs) do
    Enum.into(attrs, %{provider_event_id: nil, uid: nil})
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
      status: "confirmed"
    }

    insert(:meeting, Map.merge(defaults, attrs))
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
    insert_meeting(user, %{status: "cancelled"})
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

  test "drops bookings whose synced provider copy is present" do
    user = insert(:user)
    synced = insert_meeting(user, %{provider_event_id: "prov-event-1"})
    unsynced = insert_meeting(user, %{title: "Unsynced"})

    {start_dt, end_dt} = window()
    cached = [cached_event(provider_event_id: "prov-event-1", uid: "prov-event-1@google.com")]

    events = CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt, cached)

    assert Enum.map(events, & &1.meeting_id) == [unsynced.id]
    refute Enum.any?(events, &(&1.meeting_id == synced.id))
  end

  test "drops a CalDAV booking whose synced copy is keyed by href, not provider event id" do
    user = insert(:user)

    # The CalDAV write path persists its caller-supplied UID (the meeting's
    # calendar_uid) and never sets
    # provider_event_id, while the synced copy carries the server's href
    # there. The only identifier the two sides share is the UID.
    synced = insert_meeting(user, %{calendar_uid: "abc123@tymeslot.com", provider_event_id: nil})
    unsynced = insert_meeting(user, %{title: "Unsynced", calendar_uid: "def456@tymeslot.com"})

    {start_dt, end_dt} = window()

    cached = [
      cached_event(
        provider_event_id: "/calendars/sander/default/abc123@tymeslot.com.ics",
        uid: "abc123@tymeslot.com"
      )
    ]

    events = CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt, cached)

    assert Enum.map(events, & &1.meeting_id) == [unsynced.id]
    refute Enum.any?(events, &(&1.meeting_id == synced.id))
  end

  test "keeps a booking whose UID merely resembles an unrelated cached event" do
    user = insert(:user)
    booking = insert_meeting(user, %{calendar_uid: "abc123@tymeslot.com", provider_event_id: nil})

    {start_dt, end_dt} = window()
    cached = [cached_event(provider_event_id: "/calendars/x/other.ics", uid: "other@example.com")]

    events = CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt, cached)

    assert Enum.map(events, & &1.meeting_id) == [booking.id]
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
               CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt, [],
                 include_expired: true
               )

      assert event.meeting_id == lapsed.id
    end

    test "keep_mirrored keeps a booking whose synced copy is cached" do
      user = insert(:user)
      synced = insert_meeting(user, %{provider_event_id: "prov-event-1"})

      {start_dt, end_dt} = window()
      cached = [cached_event(provider_event_id: "prov-event-1", uid: "prov-event-1@google.com")]

      assert [%BookingEvent{meeting_id: id}] =
               CalendarGrid.list_booking_events_for_range(user.id, start_dt, end_dt, cached,
                 keep_mirrored: true
               )

      assert id == synced.id
    end
  end
end
