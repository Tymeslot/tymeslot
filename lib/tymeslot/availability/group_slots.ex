defmodule Tymeslot.Availability.GroupSlots do
  @moduledoc """
  Seat-aware slot enrichment for group meeting types.

  `Calculate.available_slots/6` stays seat-agnostic and filters against every
  blocking calendar event, including events belonging to live group meetings
  of the requested type (identified by `event.uid == meeting.uid`). Keeping
  those events blocking preserves the buffer protection around a group
  meeting: adjacent slots that would fail the booking-time conflict check are
  never shown. This module then:

    * adds back "joinable" slots: live meetings of the type with seats left,
      still inside the notice and booking windows, and not covered by any
      blocking event other than their own calendar event; and
    * overlays seat counts on every slot, dropping slots with no seats left
      (which also hides a just-filled slot whose calendar event has not
      synced yet).

  Slots are returned as `%{time: t, seats_left: n, capacity: c}` where `time`
  is the existing display string (e.g. `"9:00 AM"`); solo meeting types carry
  `seats_left: nil, capacity: nil`.
  """

  alias Tymeslot.Availability.Events
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Utils.{DateTimeUtils, TimeRange}

  @utc "Etc/UTC"

  @typedoc "A seat-aware slot as consumed by the booking UI."
  @type slot :: %{
          time: String.t(),
          seats_left: non_neg_integer() | nil,
          capacity: pos_integer() | nil
        }

  @typedoc "Inputs shared by the day and range overlays."
  @type overlay_context :: %{
          required(:user_timezone) => String.t(),
          required(:owner_timezone) => String.t(),
          required(:events) => [CalendarEvent.t() | map()],
          required(:config) => map()
        }

  @doc """
  Wraps plain slot strings in the seat-aware shape with `nil` seat data.
  Used for solo meeting types and the demo path.
  """
  @spec solo_slots([String.t()]) :: [slot()]
  def solo_slots(slots), do: Enum.map(slots, &%{time: &1, seats_left: nil, capacity: nil})

  @doc """
  Enriches one day's filtered slot list for a meeting type.

  Solo (or unknown) types pass through `solo_slots/1`; group types get the
  seat overlay described in the module doc.
  """
  @spec enrich_day_slots([String.t()], map() | nil, Date.t(), overlay_context()) :: [slot()]
  def enrich_day_slots(slots, meeting_type, date, context) do
    if group?(meeting_type) do
      enrich_group_day(slots, meeting_type, date, context)
    else
      solo_slots(slots)
    end
  end

  @doc """
  Overlays joinable-day availability onto a range availability map for a
  group meeting type.

  A day whose only bookable slot is an existing group meeting with seats
  left is marked unavailable by the base calculation (the meeting's own
  calendar event blocks it), so it is flipped back to available here.
  Non-group types return the map unchanged.
  """
  @spec overlay_range(
          %{String.t() => boolean()},
          map() | nil,
          Date.t(),
          Date.t(),
          overlay_context()
        ) :: %{String.t() => boolean()}
  def overlay_range(availability_map, meeting_type, start_date, end_date, context) do
    if group?(meeting_type) do
      {from_utc, to_utc} = window_utc(start_date, end_date, context.user_timezone)
      seat_counts = Seats.seat_counts_for_range(meeting_type.id, from_utc, to_utc)

      meeting_type
      |> joinable_meetings(from_utc, to_utc, seat_counts, context)
      |> Enum.map(fn {meeting, _seats_left} ->
        meeting.start_time
        |> DateTime.shift_zone!(context.user_timezone)
        |> DateTime.to_date()
        |> Date.to_string()
      end)
      |> Enum.reduce(availability_map, &Map.put(&2, &1, true))
    else
      availability_map
    end
  end

  # --- Group day enrichment ---

  defp enrich_group_day(slots, meeting_type, date, context) do
    capacity = meeting_type.max_participants
    {from_utc, to_utc} = window_utc(date, date, context.user_timezone)
    seat_counts = Seats.seat_counts_for_range(meeting_type.id, from_utc, to_utc)

    base =
      Enum.map(slots, fn slot ->
        seats_taken =
          Map.get(seat_counts, slot_start_utc(date, slot, context.user_timezone), 0)

        %{time: slot, seats_left: capacity - seats_taken, capacity: capacity}
      end)

    joinable =
      meeting_type
      |> joinable_meetings(from_utc, to_utc, seat_counts, context)
      |> Enum.map(fn {meeting, seats_left} ->
        local_start = DateTime.shift_zone!(meeting.start_time, context.user_timezone)

        %{
          time: TimeSlots.format_datetime_slot(local_start),
          seats_left: seats_left,
          capacity: capacity
        }
      end)

    (base ++ joinable)
    |> Enum.uniq_by(& &1.time)
    |> Enum.filter(&(&1.seats_left > 0))
    |> Enum.sort_by(&TimeSlots.parse_time_slot(&1.time), Time)
  end

  # --- Joinable meetings ---

  # A live group meeting is joinable when seats remain, the booker can still
  # give the required notice, the slot sits inside the booking window, and no
  # blocking calendar event other than the meeting's own event covers it.
  defp joinable_meetings(meeting_type, from_utc, to_utc, seat_counts, context) do
    %{user_timezone: user_timezone, config: config} = context
    capacity = meeting_type.max_participants
    event_pairs = blocking_events_with_uid(context)
    now = DateTimeUtils.now_in_timezone(user_timezone)

    min_advance_minutes = Map.get(config, :min_advance_hours, 3) * 60
    max_advance_days = Map.get(config, :max_advance_booking_days, 90)
    buffer_minutes = Map.get(config, :buffer_minutes, 15)

    meeting_type.id
    |> GroupMeetingQueries.list_live_for_type_in_range(from_utc, to_utc)
    |> Enum.map(fn meeting ->
      {meeting, capacity - Map.get(seat_counts, meeting.start_time, 0)}
    end)
    |> Enum.filter(fn {meeting, seats_left} ->
      other_events = for {uid, event} <- event_pairs, uid != meeting.uid, do: event

      seats_left > 0 and
        TimeRange.meets_minimum_notice?(meeting.start_time, now, min_advance_minutes) and
        TimeRange.within_booking_window?(meeting.start_time, now, max_advance_days) and
        not TimeRange.has_conflict_with_events?(
          meeting.start_time,
          meeting.end_time,
          other_events,
          buffer_minutes
        )
    end)
  end

  defp blocking_events_with_uid(%{
         events: events,
         owner_timezone: owner_timezone,
         user_timezone: user_timezone
       }) do
    events
    |> Enum.filter(&CalendarEvent.blocking?/1)
    |> Enum.flat_map(fn event ->
      case Events.convert_events_to_timezone([event], owner_timezone, user_timezone) do
        [converted] -> [{event_uid(event), converted}]
        _other -> []
      end
    end)
  end

  defp event_uid(%CalendarEvent{uid: uid}), do: uid
  defp event_uid(%{} = event), do: Map.get(event, :uid) || Map.get(event, "uid")

  defp group?(%MeetingTypeSchema{} = meeting_type), do: MeetingTypeSchema.group?(meeting_type)
  defp group?(_other), do: false

  defp window_utc(start_date, end_date, user_timezone) do
    from_local = DateTimeUtils.create_datetime_safe(start_date, ~T[00:00:00], user_timezone)

    to_local =
      DateTimeUtils.create_datetime_safe(Date.add(end_date, 1), ~T[00:00:00], user_timezone)

    {
      DateTime.shift_zone!(from_local, @utc),
      to_local |> DateTime.add(-1, :second) |> DateTime.shift_zone!(@utc)
    }
  end

  defp slot_start_utc(date, slot, user_timezone) do
    time = TimeSlots.parse_time_slot(slot)

    date
    |> DateTimeUtils.create_datetime_safe(time, user_timezone)
    |> DateTime.shift_zone!(@utc)
    |> DateTime.truncate(:second)
  end
end
