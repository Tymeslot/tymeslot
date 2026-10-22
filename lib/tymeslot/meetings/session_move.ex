defmodule Tymeslot.Meetings.SessionMove do
  @moduledoc """
  The host moving a planned session (`Tymeslot.Meetings.PlannedSessions`)
  to another time, with everyone booked on it.

  Upstream's host reschedule request does not fit a fixed date: it voids
  the slot for all its participants and asks each to book again, and a
  fixed-date type offers nothing to book but its other dates
  (`Tymeslot.Bookings.RescheduleSeat`). So the request is refused for a
  planned session (`Tymeslot.Bookings.Policy.can_request_reschedule?/1`),
  and the host moves it here instead: the same row, the same seats, a new
  time.

  The move is checked like planning the session: the new start lies in the
  future, the host has no other booking then, and registration closes no
  later than the start. It then owes what any rescheduled meeting does:
  the host's calendar event and the video room follow the new time, the
  reminders and the host's participant list are pinned to it again, each
  seat's calendar entry gets a new revision, and every participant (and
  their guests) is emailed the new time with an updated calendar entry,
  one job per seat
  (`Tymeslot.Notifications.Email.GroupMeetingEmails`). Guests'
  answers applied to the old time and are reset, except a decline, which
  stands until the guest answers again.
  """

  require Logger

  alias Tymeslot.Bookings.{CalendarJobs, SeatEffects}
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.{GuestQueries, MeetingState, ParticipantQueries, Scheduling, VideoRooms}
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @type error ::
          :session_started
          | :start_in_past
          | :invalid_registration_close
          | :time_conflict
          | term()

  @doc """
  Moves `session` to start at `starts_at`, keeping its length, with
  registration closing at `closes_at` (`nil`: at the new start).
  """
  @spec move(Meeting.t(), DateTime.t(), DateTime.t() | nil, DateTime.t()) ::
          {:ok, Meeting.t()} | {:error, error()}
  def move(%Meeting{planned: true} = session, starts_at, closes_at, now \\ Clock.utc_now()) do
    starts_at = DateTime.truncate(starts_at, :second)
    closes_at = closes_at && DateTime.truncate(closes_at, :second)

    with :ok <- check(session, starts_at, closes_at, now),
         {:ok, moved} <- write(session, starts_at, closes_at) do
      after_move(moved, session)
      {:ok, moved}
    end
  end

  defp check(session, starts_at, closes_at, now) do
    cond do
      MeetingState.slot_void?(session) or DateTime.compare(session.start_time, now) != :gt ->
        {:error, :session_started}

      DateTime.compare(starts_at, now) != :gt ->
        {:error, :start_in_past}

      closes_at && DateTime.compare(closes_at, starts_at) == :gt ->
        {:error, :invalid_registration_close}

      true ->
        :ok
    end
  end

  # The time, the reset reminder tracking and the next calendar revision land
  # in one write, conflict-checked against the host's other meetings as a
  # planned session is when it is added. The seats' revisions and the
  # calendar job go in the same transaction, so a refused move changes
  # nothing.
  defp write(session, starts_at, closes_at) do
    length = DateTime.diff(session.end_time, session.start_time)

    attrs =
      Map.merge(
        %{
          start_time: starts_at,
          end_time: DateTime.add(starts_at, length),
          registration_closes_at: closes_at,
          reminders_sent: [],
          reminder_email_sent: false,
          ical_sequence: session.ical_sequence + 1
        },
        VideoRooms.refreshed_join_url_attrs(session, starts_at)
      )

    Repo.transaction(fn ->
      with {:ok, moved} <-
             Scheduling.update_meeting_with_conflict_check(session, attrs,
               enforce_booking_limits: false
             ),
           _seats = ParticipantQueries.bump_ical_sequence_for_meeting(moved.id),
           _guests = GuestQueries.reset_for_moved_session(moved.id),
           {:ok, _job} <- CalendarJobs.schedule_job(moved, "update") do
        moved
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp after_move(moved, original) do
    SeatEffects.broadcast_and_invalidate(moved)
    :ok = EmailScheduler.reschedule_registration_closed(original, moved)
    sync_video_room(moved)
    repin_reminders(moved)
    tell_participants(moved, original)
  end

  defp sync_video_room(%{video_room_id: nil}), do: :ok

  defp sync_video_room(moved) do
    with {:error, reason} <- VideoSyncWorker.enqueue(moved.id, "update") do
      log("video sync", moved, reason)
    end
  end

  defp repin_reminders(moved) do
    Orchestrator.cancel_reminder_notifications(moved)

    with {:error, reason} <- Orchestrator.schedule_reminder_notifications(moved) do
      log("reminders", moved, reason)
    end
  end

  defp tell_participants(moved, original) do
    from = DateTime.to_iso8601(original.start_time)

    for participant <- ParticipantQueries.list_live_for_meeting(moved.id) do
      with {:error, reason} <-
             EmailScheduler.schedule_seat_session_moved(moved.id, participant.id, from) do
        log("participant email", moved, reason)
      end
    end

    :ok
  end

  defp log(what, meeting, reason) do
    Logger.error("Failed to schedule after moving a planned session",
      effect: what,
      meeting_id: meeting.id,
      reason: LogFormat.reason(reason)
    )
  end
end
