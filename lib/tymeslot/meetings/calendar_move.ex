defmodule Tymeslot.Meetings.CalendarMove do
  @moduledoc """
  Moves a booking to the time its calendar event was moved to.

  When the host drags a booked meeting to another time in their own calendar,
  sync flags the booking `"externally_modified"`. This module decides whether
  the booking can follow the event (`offer/1`), at what time, and performs the
  move (`move/3`).

  The offer is a cheap, honest rule: it is made only when the cached event
  gives an unambiguous new time. Each refusal exists because following the
  calendar would otherwise be wrong:

  - `:not_flagged` — nothing was detected, or the host already dismissed it.
  - `:group_meeting` — a group meeting has seats and attendees whose time
    cannot follow a single event.
  - `:not_confirmed` — only a confirmed booking has a time to move; an
    unapproved or cancelled one is handled by its own lifecycle.
  - `:awaiting_new_time` — a pending reschedule request voided the slot and
    Tymeslot deleted (or is deleting) the event on purpose, so a leftover
    cached row is not a time the host chose; moving would clear the request
    with no event in the calendar.
  - `:calendar_write_pending` — Tymeslot's own queued calendar write has not
    landed, so the cache may still hold the old time and the flag may be an
    echo of our own change. Offering would move the booking back.
  - `:event_not_found` — the cache has no row to read a time from.
  - `:all_day` — an all-day event carries a date, not a time of day.
  - `:invalid_times` — an event that does not end after it starts is malformed.
  - `:unchanged` — the event already sits at the booking's time.
  - `:in_past` — a booking is never moved to a start that has passed.

  `move/3` adds one of its own: `:offer_changed`, the calendar time is no
  longer the one the host confirmed.

  Nothing here checks availability, buffers, notice or booking limits: the
  host moved the event themselves, so the booking follows it. And nothing is
  written back to the calendar; the event is already where the host put it.

  `move/3` takes a fresh offer instead of trusting a time handed in, and
  moves the booking only when that offer is the time the host confirmed: the
  event may have moved again since the host was shown it, and the booking
  must never land on a time the host did not agree to. It then re-checks the
  booking under its row lock before writing, so a second confirm of an
  already-moved booking (the move clears the flag) is refused as
  `:not_flagged`, and so is a move racing an attendee's reschedule.
  """

  alias Tymeslot.Bookings.FollowCalendar
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings.CalendarEventLink
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Workers.CalendarEventWorker

  @externally_modified "externally_modified"

  @type offer :: %{start_time: DateTime.t(), end_time: DateTime.t()}
  @type refusal ::
          :not_flagged
          | :group_meeting
          | :not_confirmed
          | :awaiting_new_time
          | :calendar_write_pending
          | :event_not_found
          | :all_day
          | :invalid_times
          | :unchanged
          | :in_past
  @type move_error ::
          refusal() | :offer_changed | :not_found | :slot_taken | :failed_to_update_meeting

  @doc """
  The time `meeting` can follow its calendar event to, or why it cannot.

  Times are UTC, truncated to the second like every stored booking time.
  """
  @spec offer(MeetingSchema.t()) :: {:ok, offer()} | {:error, refusal()}
  def offer(%MeetingSchema{} = meeting) do
    with :ok <- check_meeting(meeting),
         :ok <- check_no_pending_write(meeting),
         {:ok, event} <- find_event(meeting) do
      check_event(meeting, event)
    end
  end

  @doc """
  The offers for the movable meetings among `meetings`, keyed by meeting id.

  Meetings that fail the struct checks cost no query.
  """
  @spec offers([MeetingSchema.t()]) :: %{String.t() => offer()}
  def offers(meetings) do
    for meeting <- meetings, {:ok, offer} <- [offer(meeting)], into: %{} do
      {meeting.id, offer}
    end
  end

  @doc """
  Moves the organiser's booking to its calendar event's current time, which
  must be `confirmed`, the offer the host agreed to.

  The meeting is loaded through the organiser, so another user's id is
  `:not_found`. The offer is taken afresh, and a fresh offer that differs from
  `confirmed` is `:offer_changed`: the host is asked again rather than moved
  to a time they never saw.
  """
  @spec move(String.t(), integer(), offer()) :: {:ok, MeetingSchema.t()} | {:error, move_error()}
  def move(
        meeting_id,
        organizer_user_id,
        %{start_time: %DateTime{}, end_time: %DateTime{}} = confirmed
      ) do
    with {:ok, meeting} <- MeetingQueries.get_meeting_for_organizer(meeting_id, organizer_user_id),
         {:ok, offer} <- offer(meeting),
         :ok <- check_confirmed(offer, confirmed) do
      FollowCalendar.execute(meeting, offer.start_time, offer.end_time, guard: &check_meeting/1)
    end
  end

  defp check_confirmed(offer, confirmed) do
    if DateTime.compare(offer.start_time, confirmed.start_time) == :eq and
         DateTime.compare(offer.end_time, confirmed.end_time) == :eq,
       do: :ok,
       else: {:error, :offer_changed}
  end

  # The checks that need only the struct, cheapest first.
  defp check_meeting(%MeetingSchema{calendar_sync_status: @externally_modified} = meeting) do
    cond do
      meeting.calendar_sync_status_dismissed_at != nil -> {:error, :not_flagged}
      MeetingSchema.group?(meeting) -> {:error, :group_meeting}
      meeting.status != "confirmed" -> {:error, :not_confirmed}
      not MeetingState.expects_calendar_event?(meeting) -> {:error, :awaiting_new_time}
      true -> :ok
    end
  end

  defp check_meeting(_meeting), do: {:error, :not_flagged}

  defp check_no_pending_write(meeting) do
    if Jobs.pending_meeting_job?(CalendarEventWorker, meeting.id) do
      {:error, :calendar_write_pending}
    else
      :ok
    end
  end

  # A meeting without an integration has nothing cached to read.
  defp find_event(%{calendar_integration_id: nil}), do: {:error, :event_not_found}

  defp find_event(meeting) do
    case ProviderCalendarEventQueries.get_by_identifiers(
           meeting.calendar_integration_id,
           CalendarEventLink.identifiers(meeting)
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> {:error, :event_not_found}
    end
  end

  defp check_event(_meeting, %{all_day: true}), do: {:error, :all_day}

  defp check_event(meeting, event) do
    start_time = DateTime.truncate(event.start_at, :second)
    end_time = DateTime.truncate(event.end_at, :second)

    cond do
      DateTime.compare(end_time, start_time) != :gt ->
        {:error, :invalid_times}

      DateTime.compare(start_time, meeting.start_time) == :eq and
          DateTime.compare(end_time, meeting.end_time) == :eq ->
        {:error, :unchanged}

      DateTime.compare(start_time, Clock.utc_now()) != :gt ->
        {:error, :in_past}

      true ->
        {:ok, %{start_time: start_time, end_time: end_time}}
    end
  end
end
