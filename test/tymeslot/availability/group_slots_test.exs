defmodule Tymeslot.Availability.GroupSlotsTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.GroupSlots
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes

  @timezone "Etc/UTC"

  setup do
    %{user: user, profile_id: profile_id} = create_bookable_profile(timezone: @timezone)
    meeting_type = insert(:meeting_type, user: user, max_participants: 3, duration_minutes: 30)
    date = next_bookable_weekday()

    config = %{
      profile_id: profile_id,
      max_advance_booking_days: 90,
      min_advance_hours: 3,
      buffer_minutes: 15
    }

    %{user: user, meeting_type: meeting_type, date: date, config: config}
  end

  defp context(events, config) do
    %{user_timezone: @timezone, owner_timezone: @timezone, events: events, config: config}
  end

  defp slot_start(date, slot_time) do
    DateTime.new!(date, slot_time, @timezone)
  end

  defp book_seat!(ctx, start_time, email, guest_emails \\ []) do
    {:ok, booking} =
      GroupScheduling.book_seat(
        %{
          uid: UUID.generate(),
          title: ctx.meeting_type.name,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute),
          duration: 30,
          status: "confirmed",
          organizer_user_id: ctx.user.id,
          organizer_name: "Organiser",
          organizer_email: "organiser@example.com",
          meeting_type_id: ctx.meeting_type.id
        },
        %{
          participant: %{
            name: "Booker #{email}",
            email: email,
            timezone: @timezone,
            locale: "en",
            custom_field_answers: %{}
          },
          guest_emails: guest_emails,
          max_participants: ctx.meeting_type.max_participants
        }
      )

    booking
  end

  defp own_event(meeting) do
    %{uid: meeting.calendar_uid, start_time: meeting.start_time, end_time: meeting.end_time}
  end

  defp base_slots(date, events, config) do
    {:ok, slots} = Calculate.available_slots(date, 30, @timezone, @timezone, events, config)
    slots
  end

  test "solo enrichment wraps slots with nil seat data" do
    assert GroupSlots.solo_slots(["11:00 AM", "11:30 AM"]) == [
             %{time: "11:00 AM", seats_left: nil, capacity: nil},
             %{time: "11:30 AM", seats_left: nil, capacity: nil}
           ]
  end

  test "an empty day offers full capacity on every slot", ctx do
    slots = base_slots(ctx.date, [], ctx.config)
    assert slots != []

    enriched =
      GroupSlots.enrich_day_slots(slots, ctx.meeting_type, ctx.date, context([], ctx.config))

    assert Enum.all?(enriched, &(&1.capacity == 3 and &1.seats_left == 3))
    assert Enum.map(enriched, & &1.time) == slots
  end

  test "a partially filled meeting is joinable when the provider reports its own event id",
       ctx do
    start_time = slot_start(ctx.date, ~T[11:00:00])
    %{meeting: meeting} = book_seat!(ctx, start_time, "one@example.com")

    # Google and Outlook list events under their own event id, not under the
    # meeting's iCal uid, so a set built from `uid` alone never matches and
    # leaves every joinable slot blocked.
    {:ok, meeting} =
      MeetingQueries.update_meeting(meeting, %{provider_event_id: "google-event-abc"})

    events = [%{uid: "google-event-abc", start_time: start_time, end_time: meeting.end_time}]

    slots = base_slots(ctx.date, events, ctx.config)
    refute "11:00 AM" in slots

    enriched =
      GroupSlots.enrich_day_slots(slots, ctx.meeting_type, ctx.date, context(events, ctx.config))

    assert %{seats_left: 2, capacity: 3} = Enum.find(enriched, &(&1.time == "11:00 AM"))
  end

  test "a partially filled meeting is joinable while buffer-adjacent slots stay blocked",
       ctx do
    start_time = slot_start(ctx.date, ~T[11:00:00])
    %{meeting: meeting} = book_seat!(ctx, start_time, "one@example.com")
    events = [own_event(meeting)]

    slots = base_slots(ctx.date, events, ctx.config)
    # The meeting's own event hides its slot and the buffered neighbours.
    refute "11:00 AM" in slots
    refute "11:30 AM" in slots

    enriched =
      GroupSlots.enrich_day_slots(slots, ctx.meeting_type, ctx.date, context(events, ctx.config))

    joinable = Enum.find(enriched, &(&1.time == "11:00 AM"))
    assert %{seats_left: 2, capacity: 3} = joinable
    # The buffer-adjacent slot must NOT come back: booking it would fail the
    # conflict check against the live 11:00 meeting.
    refute Enum.any?(enriched, &(&1.time == "11:30 AM"))
  end

  test "guests reduce the advertised seats", ctx do
    start_time = slot_start(ctx.date, ~T[11:00:00])

    %{meeting: meeting} =
      book_seat!(ctx, start_time, "host@example.com", ["g1@example.com"])

    events = [own_event(meeting)]
    slots = base_slots(ctx.date, events, ctx.config)

    enriched =
      GroupSlots.enrich_day_slots(slots, ctx.meeting_type, ctx.date, context(events, ctx.config))

    assert %{seats_left: 1} = Enum.find(enriched, &(&1.time == "11:00 AM"))
  end

  test "a full slot is dropped even before its calendar event syncs", ctx do
    start_time = slot_start(ctx.date, ~T[11:00:00])
    %{meeting: meeting} = book_seat!(ctx, start_time, "one@example.com")
    book_seat!(ctx, start_time, "two@example.com")
    book_seat!(ctx, start_time, "three@example.com")

    # Without the synced event the base pipeline still offers 11:00 AM; the
    # seat overlay must drop it.
    no_event_slots = base_slots(ctx.date, [], ctx.config)
    assert "11:00 AM" in no_event_slots

    enriched =
      GroupSlots.enrich_day_slots(
        no_event_slots,
        ctx.meeting_type,
        ctx.date,
        context([], ctx.config)
      )

    refute Enum.any?(enriched, &(&1.time == "11:00 AM"))

    # With the synced event it is hidden by the base pipeline and must not be
    # added back either.
    with_event_slots = base_slots(ctx.date, [own_event(meeting)], ctx.config)

    enriched_with_event =
      GroupSlots.enrich_day_slots(
        with_event_slots,
        ctx.meeting_type,
        ctx.date,
        context([own_event(meeting)], ctx.config)
      )

    refute Enum.any?(enriched_with_event, &(&1.time == "11:00 AM"))
  end

  test "a joinable meeting covered by an unrelated blocking event is not offered", ctx do
    start_time = slot_start(ctx.date, ~T[11:00:00])
    %{meeting: meeting} = book_seat!(ctx, start_time, "one@example.com")

    external = %{
      uid: "external-blocker",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute)
    }

    events = [own_event(meeting), external]
    slots = base_slots(ctx.date, events, ctx.config)

    enriched =
      GroupSlots.enrich_day_slots(slots, ctx.meeting_type, ctx.date, context(events, ctx.config))

    refute Enum.any?(enriched, &(&1.time == "11:00 AM"))
  end

  test "lowering the type's max_participants does not change an existing booked slot's capacity",
       ctx do
    start_time = slot_start(ctx.date, ~T[11:00:00])
    %{meeting: meeting} = book_seat!(ctx, start_time, "one@example.com")
    events = [own_event(meeting)]
    slots = base_slots(ctx.date, events, ctx.config)

    {:ok, lowered_type} =
      MeetingTypes.update_meeting_type(ctx.meeting_type, %{max_participants: 2})

    enriched =
      GroupSlots.enrich_day_slots(slots, lowered_type, ctx.date, context(events, ctx.config))

    # The meeting was created with capacity 3 (the type's value at the
    # time); it keeps that capacity for its whole life even though the
    # type's live value is now lower than the seats already taken.
    assert %{capacity: 3, seats_left: 2} = Enum.find(enriched, &(&1.time == "11:00 AM"))
  end

  test "overlay_range flips a day back to available when a joinable meeting exists", ctx do
    start_time = slot_start(ctx.date, ~T[11:00:00])
    %{meeting: meeting} = book_seat!(ctx, start_time, "one@example.com")
    events = [own_event(meeting)]
    date_string = Date.to_string(ctx.date)

    base_map = %{date_string => false}

    overlaid =
      GroupSlots.overlay_range(
        base_map,
        ctx.meeting_type,
        ctx.date,
        ctx.date,
        context(events, ctx.config)
      )

    assert overlaid[date_string] == true

    # Fill the meeting: the day must stay as the base map says.
    book_seat!(ctx, start_time, "two@example.com")
    book_seat!(ctx, start_time, "three@example.com")

    still_false =
      GroupSlots.overlay_range(
        base_map,
        ctx.meeting_type,
        ctx.date,
        ctx.date,
        context(events, ctx.config)
      )

    assert still_false[date_string] == false
  end

  test "overlay_range leaves solo types untouched", ctx do
    solo_type = insert(:meeting_type, user: ctx.user, max_participants: 1)
    base_map = %{Date.to_string(ctx.date) => false}

    assert GroupSlots.overlay_range(
             base_map,
             solo_type,
             ctx.date,
             ctx.date,
             context([], ctx.config)
           ) == base_map
  end
end
