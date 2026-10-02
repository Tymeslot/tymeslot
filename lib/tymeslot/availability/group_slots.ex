defmodule Tymeslot.Availability.GroupSlots do
  @moduledoc """
  Seat-aware slot enrichment for group meeting types.

  `Calculate.available_slots/6` and `Calculate.range_availability/6` own
  every timing rule: minimum notice, the booking window, and buffered
  event-conflict checking. This module never re-derives them; instead it
  tells `Calculate` which live meetings of this type still have a seat free
  via `joinable_uids/3` and its `:ignore_event_uids` option, so a slot
  occupied by one of them is only unblocked *for itself* — every other slot
  still sees its buffer (see `Tymeslot.Availability.Conflicts`). This module
  then owns exactly the seat-count fact `Calculate` has no reason to know:

    * overlaying seat counts on every slot; and
    * dropping slots with no seats left (which also hides a just-filled slot
      whose calendar event has not synced yet).

  Slots are returned as `%{time: t, seats_left: n, capacity: c}` where `time`
  is the existing display string (e.g. `"9:00 AM"`); solo meeting types carry
  `seats_left: nil, capacity: nil`.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Utils.DateTimeUtils

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
  calendar event blocks it), so it is flipped back to available here by
  re-running `Calculate.range_availability/6` with that meeting's uid
  ignored, and taking the union with the given map. Non-group types, and
  types with no live joinable meeting in range, return the map unchanged.
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
      {from_utc, to_utc} = utc_window(start_date, end_date, context.user_timezone)
      ignore_uids = joinable_uids(meeting_type, from_utc, to_utc)

      if MapSet.size(ignore_uids) == 0 do
        availability_map
      else
        {:ok, joinable_map} =
          Calculate.range_availability(
            start_date,
            end_date,
            context.owner_timezone,
            context.user_timezone,
            context.events,
            Map.put(context.config, :ignore_event_uids, ignore_uids)
          )

        Map.merge(availability_map, joinable_map, fn _date, was, now -> was or now end)
      end
    else
      availability_map
    end
  end

  @doc """
  Calendar-event ids of the live meetings of `meeting_type` within
  `[from_utc, to_utc]` that still have a seat free.

  A pure capacity lookup: it says nothing about minimum notice, the booking
  window, or event conflicts, which remain `Calculate`'s sole concern. Also
  used by `Tymeslot.Bookings.Create` to drop a group booking's own event
  from its booking-time conflict check.
  """
  @spec joinable_uids(map() | nil, DateTime.t(), DateTime.t()) :: MapSet.t(String.t())
  def joinable_uids(meeting_type, from_utc, to_utc) do
    meeting_type
    |> joinable_meetings(from_utc, to_utc)
    |> event_uid_set()
  end

  # A meeting's own calendar event is reported back under its iCal uid (the
  # meeting's `calendar_uid`, never its `uid`) by CalDAV, but under the
  # provider's own event id by Google and Outlook, which is what
  # `provider_event_id` snapshots at creation time. Both forms go into the
  # set, so the meeting sheds its own event whichever provider holds it;
  # matching only on the iCal uid silently never fires on Google or Outlook
  # and leaves every joinable group slot blocked.
  defp event_uid_set(meetings) do
    meetings
    |> Enum.flat_map(&[&1.calendar_uid, &1.provider_event_id])
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp joinable_meetings(meeting_type, from_utc, to_utc) do
    if group?(meeting_type) do
      seat_counts = Seats.seat_counts_for_range(meeting_type.id, from_utc, to_utc)

      meeting_type
      |> live_meetings(from_utc, to_utc)
      |> with_seats_left(seat_counts)
    else
      []
    end
  end

  # Only group meetings are ever joinable. A solo meeting of the type (a
  # one-to-one booked before the type became a group type) has no participant
  # rows, so it must not read as a slot with free seats: it stays private and
  # its own calendar event keeps blocking the slot.
  defp with_seats_left(meetings, seat_counts),
    do: Enum.filter(meetings, &(seats_left(&1, seat_counts) > 0))

  defp seats_left(meeting, seat_counts) do
    if Meeting.group?(meeting),
      do: meeting.capacity - Map.get(seat_counts, meeting.start_time, 0),
      else: 0
  end

  # --- Group day enrichment ---

  defp enrich_group_day(slots, meeting_type, date, context) do
    {from_utc, to_utc} = utc_window(date, date, context.user_timezone)
    slot_ctx = slot_context(meeting_type, from_utc, to_utc)

    (slots ++ joinable_slots(meeting_type, date, context, slot_ctx.ignore_uids))
    |> Enum.uniq()
    |> Enum.map(fn slot ->
      start_time = slot_start_utc(date, slot, context.user_timezone)
      # An existing meeting carries its own capacity (kept in step with the
      # type by `MeetingTypes.update_meeting_type/3`); a slot with no meeting
      # yet takes the type's current value, which is what a new meeting would
      # be created with.
      capacity = Map.get(slot_ctx.capacities, start_time, meeting_type.max_participants)

      seats_left =
        Map.get(slot_ctx.seats_left, start_time, meeting_type.max_participants)

      %{time: slot, seats_left: seats_left, capacity: capacity}
    end)
    |> Enum.filter(&(&1.seats_left > 0))
    |> Enum.sort_by(&TimeSlots.parse_time_slot(&1.time), Time)
  end

  defp live_meetings(meeting_type, from_utc, to_utc),
    do: GroupMeetingQueries.list_live_for_type_in_range(meeting_type.id, from_utc, to_utc)

  # Builds every fact `enrich_group_day/4` needs from a single pass over
  # `list_live_for_type_in_range/3` plus a single `seat_counts_for_range/3`
  # call, instead of the two independent queries `joinable_uids/3` would
  # otherwise repeat.
  defp slot_context(meeting_type, from_utc, to_utc) do
    seat_counts = Seats.seat_counts_for_range(meeting_type.id, from_utc, to_utc)
    live = live_meetings(meeting_type, from_utc, to_utc)

    ignore_uids =
      live
      |> with_seats_left(seat_counts)
      |> event_uid_set()

    %{
      ignore_uids: ignore_uids,
      # A solo meeting at a start time reads as no seats left, so the slot is
      # never offered as joinable even if its calendar event has not synced.
      seats_left:
        Enum.reduce(live, %{}, fn meeting, acc ->
          left = seats_left(meeting, seat_counts)
          Map.update(acc, meeting.start_time, left, &min(&1, left))
        end),
      capacities: Map.new(live, &{&1.start_time, &1.capacity})
    }
  end

  # Re-runs the day's slot calculation with any joinable-by-seats meeting's
  # own event ignored, so its slot passes the same notice/window/buffer
  # checks as everything else instead of a second, hand-rolled copy of them.
  defp joinable_slots(meeting_type, date, context, ignore_uids) do
    if MapSet.size(ignore_uids) == 0 do
      []
    else
      config = Map.put(context.config, :ignore_event_uids, ignore_uids)

      {:ok, slots} =
        Calculate.available_slots(
          date,
          meeting_type.duration_minutes,
          context.user_timezone,
          context.owner_timezone,
          context.events,
          config
        )

      slots
    end
  end

  defp group?(%MeetingTypeSchema{} = meeting_type), do: MeetingTypeSchema.group?(meeting_type)
  defp group?(_other), do: false

  defp utc_window(start_date, end_date, user_timezone) do
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
