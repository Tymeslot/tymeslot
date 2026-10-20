defmodule Tymeslot.CalendarGrid.BookingEvents do
  @moduledoc """
  Loads the organiser's bookings for a grid window as `BookingEvent` structs.

  This is the calendar grid's native view of Tymeslot bookings: it reads
  through the `Meetings` context and projects each live booking into the
  grid's event shape. Deduplication against provider-synced copies of the
  same bookings happens here so callers get a list that can be concatenated
  onto the cached provider events directly.
  """

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.Clock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.Seats

  @doc """
  Returns the user's live bookings overlapping `[start_dt, end_dt)` as
  `BookingEvent` structs, excluding any whose synced provider copy is already
  present.

  `cached_events` is the cached provider events loaded for the same window. A
  booking that has been written back to a connected calendar reappears in the
  cache as a `created_by_tymeslot` event; for the old grid that copy stays
  the interactive one, so the booking projection is dropped to avoid a
  duplicate block.

  Pass the cached events themselves rather than a pre-extracted key set: which
  identifier links the two sides varies by provider family, and
  `Tymeslot.Meetings.CalendarEventLink` is the one place that knows the rule.

  Options:

    * `include_expired: true` adds the requests that expired unanswered.
    * `keep_mirrored: true` keeps the bookings whose copy is cached, for a
      caller that drops the copy instead (`PreferredBookings`).
  """
  @spec list_for_range(pos_integer(), DateTime.t(), DateTime.t(), Enumerable.t(), keyword()) ::
          [BookingEvent.t()]
  def list_for_range(user_id, start_dt, end_dt, cached_events \\ [], opts \\ []) do
    now = Clock.utc_now()

    user_id
    |> meetings(start_dt, end_dt, Keyword.get(opts, :include_expired, false))
    |> drop_mirrored(cached_events, Keyword.get(opts, :keep_mirrored, false))
    |> Meetings.with_live_participants()
    |> Meetings.with_live_guests()
    |> Enum.map(&to_event(&1, now))
  end

  defp meetings(user_id, start_dt, end_dt, false),
    do: Meetings.list_meetings_in_range_for_organizer(user_id, start_dt, end_dt)

  defp meetings(user_id, start_dt, end_dt, true) do
    expired = Meetings.list_expired_requests_in_range_for_organizer(user_id, start_dt, end_dt)

    user_id
    |> meetings(start_dt, end_dt, false)
    |> Kernel.++(expired)
    |> Enum.sort_by(& &1.start_time, DateTime)
  end

  defp drop_mirrored(meetings, _cached_events, true), do: meetings

  defp drop_mirrored(meetings, cached_events, false) do
    synced_identifiers = Meetings.calendar_identifier_set(cached_events)
    Enum.reject(meetings, &Meetings.linked_to_calendar_event?(&1, synced_identifiers))
  end

  defp to_event(meeting, now) do
    %BookingEvent{
      id: "booking-#{meeting.id}",
      meeting_id: meeting.id,
      # The event-shaped identity, matching the provider copy's `uid`.
      uid: meeting.calendar_uid,
      summary: presence(meeting.title) || "Meeting",
      location: presence(meeting.location),
      start_at: meeting.start_time,
      end_at: meeting.end_time,
      attendee_name: presence(meeting.attendee_name),
      attendee_email: presence(meeting.attendee_email),
      join_url: Meetings.organizer_join_url(meeting),
      provider_event_id: meeting.provider_event_id,
      meeting_type: presence(meeting.meeting_type),
      approval_deadline_at: meeting.approval_deadline_at,
      participants: participants(meeting),
      guests:
        Enum.map(meeting.guests, &%{name: presence(&1.name), email: &1.email, status: &1.status}),
      capacity: meeting.capacity,
      seats_taken: seats_taken(meeting),
      status: meeting.status,
      request: MeetingState.awaiting_approval?(meeting),
      expired: expired_request?(meeting, now)
    }
  end

  # A request that can no longer be answered: expired by the sweep, or still
  # held past its deadline or its start, which the sweep has not reached yet
  # (it runs every 15 minutes).
  defp expired_request?(meeting, now) do
    cond do
      MeetingState.expired?(meeting) ->
        not is_nil(meeting.approval_requested_at)

      MeetingState.awaiting_approval?(meeting) ->
        MeetingState.approval_deadline_passed?(meeting, now) or
          DateTime.compare(meeting.start_time, now) != :gt

      true ->
        false
    end
  end

  # Counted like the meetings list and the booking page count them: a
  # booker's guests hold seats too.
  defp seats_taken(meeting) do
    if Meetings.group?(meeting), do: Seats.seats_taken(meeting.id), else: 0
  end

  defp participants(meeting) do
    if Meetings.group?(meeting),
      do: Enum.map(meeting.participants, &%{name: presence(&1.name), email: &1.email}),
      else: []
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
