defmodule Tymeslot.Availability.GroupDisplayBookingConsistencyTest do
  @moduledoc """
  Invariant anchors for group meeting types: a slot shown by the seat-aware
  display pipeline must be bookable, and a full slot must be neither shown
  nor bookable, even while the group meeting's own calendar event blocks the
  window for every other purpose.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.GroupSlots
  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.TestMocks

  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()

    %{user: user, profile_id: profile_id} = create_bookable_profile(timezone: @timezone)
    meeting_type = insert(:meeting_type, user: user, max_participants: 2, duration_minutes: 30)
    date = next_bookable_weekday()

    config = %{
      profile_id: profile_id,
      max_advance_booking_days: 90,
      min_advance_hours: 3,
      buffer_minutes: 15
    }

    %{user: user, meeting_type: meeting_type, date: date, config: config}
  end

  defp displayed_slots(ctx, events) do
    {:ok, slots} =
      Calculate.available_slots(ctx.date, 30, @timezone, @timezone, events, ctx.config)

    GroupSlots.enrich_day_slots(slots, ctx.meeting_type, ctx.date, %{
      user_timezone: @timezone,
      owner_timezone: @timezone,
      events: events,
      config: ctx.config
    })
  end

  defp book(ctx, slot_time, email) do
    Create.execute(
      %{
        date: ctx.date,
        time: slot_time,
        duration: "30min",
        user_timezone: @timezone,
        organizer_user_id: ctx.user.id,
        meeting_type_id: ctx.meeting_type.id
      },
      %{"name" => "Booker #{email}", "email" => email, "message" => ""},
      []
    )
  end

  defp stub_calendar_events(events) do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start_date, _end_date ->
      {:ok, events}
    end)
  end

  defp own_event(meeting) do
    %{uid: meeting.uid, start_time: meeting.start_time, end_time: meeting.end_time}
  end

  test "a joinable group slot shown by the display is bookable despite its own event", ctx do
    stub_calendar_events([])

    [first_slot | _rest] = displayed_slots(ctx, [])
    assert {:ok, meeting} = book(ctx, first_slot.time, "one@example.com")

    # From now on the meeting's calendar event exists and blocks the window.
    events = [own_event(meeting)]
    stub_calendar_events(events)

    shown = displayed_slots(ctx, events)
    joinable = Enum.find(shown, &(&1.time == first_slot.time))
    assert %{seats_left: 1, capacity: 2} = joinable

    # The invariant: the shown slot books successfully through the full
    # booking flow, including the fresh calendar check.
    assert {:ok, joined} = book(ctx, first_slot.time, "two@example.com")
    assert joined.id == meeting.id
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
  end

  test "a full group slot is neither shown nor bookable", ctx do
    stub_calendar_events([])

    [first_slot | _rest] = displayed_slots(ctx, [])
    {:ok, meeting} = book(ctx, first_slot.time, "one@example.com")

    events = [own_event(meeting)]
    stub_calendar_events(events)
    {:ok, _joined} = book(ctx, first_slot.time, "two@example.com")

    shown = displayed_slots(ctx, events)
    refute Enum.any?(shown, &(&1.time == first_slot.time))

    assert {:error, :slot_taken} = book(ctx, first_slot.time, "three@example.com")
  end

  test "the own-event filter only ever removes the joinable meeting's event", ctx do
    stub_calendar_events([])
    [first_slot | _rest] = displayed_slots(ctx, [])
    {:ok, meeting} = book(ctx, first_slot.time, "one@example.com")

    # An unrelated blocking event over the same window must still refuse the
    # booking, exactly as the display hides the slot (see GroupSlotsTest).
    external = %{
      uid: "external-blocker",
      start_time: meeting.start_time,
      end_time: meeting.end_time
    }

    stub_calendar_events([own_event(meeting), external])

    shown = displayed_slots(ctx, [own_event(meeting), external])
    refute Enum.any?(shown, &(&1.time == first_slot.time))

    assert {:error, :slot_taken} = book(ctx, first_slot.time, "two@example.com")

    assert GroupMeetingQueries.get_live_at(ctx.meeting_type.id, meeting.start_time)
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
  end
end
