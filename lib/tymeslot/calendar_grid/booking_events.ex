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
  alias Tymeslot.Meetings.HostManaged
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.MeetingTypes

  @doc """
  Returns the user's live bookings overlapping `[start_dt, end_dt)` as
  `BookingEvent` structs, including those written back to a connected
  calendar: the caller draws a booking in place of its calendar copy
  (`PreferredBookings`).

  Options:

    * `include_expired: true` adds the requests that expired unanswered.
  """
  @spec list_for_range(pos_integer(), DateTime.t(), DateTime.t(), keyword()) ::
          [BookingEvent.t()]
  def list_for_range(user_id, start_dt, end_dt, opts \\ []) do
    now = Clock.utc_now()

    meetings =
      user_id
      |> meetings(start_dt, end_dt, Keyword.get(opts, :include_expired, false))
      |> Meetings.with_live_people()

    # Only a booking whose event the host moved costs a query here.
    offers = Meetings.calendar_move_offers(meetings)

    Enum.map(meetings, &to_event(&1, now, offers[&1.id]))
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

  defp to_event(meeting, now, move_offer) do
    %BookingEvent{
      id: "booking-#{meeting.id}",
      meeting_id: meeting.id,
      # The event-shaped identity, matching the provider copy's `uid`.
      uid: meeting.calendar_uid,
      summary: presence(meeting.title) || "Meeting",
      # A default location label ("In person") reads in the dashboard's language.
      location: presence(MeetingTypes.display_location(meeting.location, meeting.location_kind)),
      start_at: meeting.start_time,
      end_at: meeting.end_time,
      attendee_name: attendee_name(meeting),
      attendee_email: attendee_email(meeting),
      join_url: Meetings.organizer_join_url(meeting),
      provider_event_id: meeting.provider_event_id,
      meeting_type: presence(meeting.meeting_type),
      approval_deadline_at: meeting.approval_deadline_at,
      participants: participants(meeting),
      guests:
        Enum.map(meeting.guests, &%{name: presence(&1.name), email: &1.email, status: &1.status}),
      capacity: meeting.capacity,
      planned: meeting.planned,
      seats_taken: seats_taken(meeting),
      # Event-shaped, like a provider copy: the grid reads statuses as strings.
      status: Atom.to_string(meeting.status),
      request: MeetingState.awaiting_approval?(meeting),
      expired: expired_request?(meeting, now),
      move_offer: move_offer
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

  # The person the grid names under a booking, and their address. A meeting
  # the host manages (`HostManaged.managed?/1`) has no such person: the one
  # in its attendee fields is only the first of its guests, so naming them
  # would read as if they had booked it.
  defp attendee_name(meeting) do
    if HostManaged.managed?(meeting), do: nil, else: presence(meeting.attendee_name)
  end

  defp attendee_email(meeting) do
    if HostManaged.managed?(meeting), do: nil, else: presence(meeting.attendee_email)
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
