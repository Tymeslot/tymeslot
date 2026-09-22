defmodule Tymeslot.Meetings.BusyPeriods do
  @moduledoc """
  The organiser's own bookings, shaped so the availability engine can weigh
  them alongside provider calendar events.

  A booking page used to compute its offer from connected calendars alone, so a
  booking blocked its own slot only once `Tymeslot.Workers.CalendarEventWorker`
  had mirrored it onto a provider calendar: never, for a host with no calendar
  connected, not yet during the sync window, and not at all while a paid
  booking sits in `awaiting_payment` (whose calendar side effects are deferred
  until Stripe confirms). The submit has always refused from the meetings table
  itself, through `MeetingConflictQueries.count_locked_conflicts/4`, so the grid
  offered times the submit then rejected and the booker was told the slot had
  gone only after filling in the form. Merging the two sources here is what
  makes the display path and the submit answer from the same facts, and
  `MeetingListQueries.list_for_organizer_in_range/3` selects on the same
  `MeetingState.where_slot_live/1` the submit's count does, so they cannot
  drift.

  ## A booking outranks its own mirror

  Once the provider event exists, a booking and its mirror are one busy period
  described twice. Overlap checking is idempotent, so a plain union would still
  compute the right slots today, but the two copies can disagree: a host who
  marks the event free in Google, or edits its time before sync reconciles it,
  would otherwise have that softer copy decide what the page offers. The
  meeting is the record the submit locks, so the mirror is dropped and the
  booking stands. `Tymeslot.Meetings.CalendarEventLink` owns which event that
  is, because the identifier the two sides share differs by provider family.
  """

  alias Tymeslot.Meetings.CalendarEventLink
  alias Tymeslot.Meetings.MeetingListQueries

  @doc """
  Returns `calendar_events` with the organiser's live bookings overlapping
  `[from, to)` merged in, each mirrored event replaced by the booking it
  mirrors.

  Bookings are projected to the plain `start_time` / `end_time` map the
  fresh-fetch providers already return, which
  `Tymeslot.Availability.Events.convert_events_to_timezone/3` consumes
  directly. The projection deliberately carries no `status` or `transparency`:
  those are the two fields `CalendarEvent.blocking?/1` can clear an event on,
  and a live booking blocks unconditionally — the decision was already taken by
  the query that selected it.

  Both identifiers travel with the projection so that a caller excluding one
  meeting from its own offer, as a reschedule page does through
  `Tymeslot.Meetings.reject_calendar_event_mirrors/2`, drops the booking as
  well as its mirror.
  """
  @spec merge(Enumerable.t(), pos_integer(), DateTime.t(), DateTime.t()) :: [map()]
  def merge(calendar_events, organizer_user_id, %DateTime{} = from, %DateTime{} = to)
      when is_integer(organizer_user_id) do
    meetings = MeetingListQueries.list_for_organizer_in_range(organizer_user_id, from, to)
    booked_identifiers = CalendarEventLink.identifier_set(meetings)

    calendar_events
    |> Enum.reject(&CalendarEventLink.linked?(&1, booked_identifiers))
    |> Enum.concat(Enum.map(meetings, &to_busy_period/1))
  end

  defp to_busy_period(meeting) do
    %{
      uid: meeting.uid,
      provider_event_id: meeting.provider_event_id,
      start_time: meeting.start_time,
      end_time: meeting.end_time
    }
  end
end
