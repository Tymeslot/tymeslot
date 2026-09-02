defmodule Tymeslot.Bookings.CancelSeat do
  @moduledoc """
  Cancels a single participant's seat on a group meeting, from their
  tokenised management link.

  The transaction locks the meeting row `FOR UPDATE` before cancelling the
  participant, so it serialises against `GroupScheduling.book_seat/3`, which
  takes the same lock. That ordering is what makes "am I the last leaver?" a
  safe question to ask: without it, two participants cancelling at once each
  see the other still live and neither cancels the meeting, and a booker can
  slip onto a slot that is about to be cancelled.

  Cancelling the participant also stops their guests counting towards seats
  (seat maths only counts guests of live participants) and makes their RSVP
  links inert (`Tymeslot.Meetings.Guests` refuses RSVPs for cancelled
  participants).

  After commit, `Tymeslot.Bookings.SeatRelease.release/1` decides under that
  same lock whether the slot is now empty:

    * last leaver: the meeting is cancelled there (calendar event deleted,
      organiser notified). The leaver still gets their own seat-cancellation
      email from here, since they are no longer a live recipient of the
      meeting; the organiser is not emailed twice.
    * seats remain: the host calendar event is refreshed so its participant
      list matches the live participants, and both the participant and the
      organiser are emailed.

  A seat-availability broadcast and an availability-cache invalidation are
  published after commit in both cases.
  """

  require Logger

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo

  @spec execute(String.t()) ::
          {:ok, :seat_cancelled | :meeting_cancelled} | {:error, term()}
  def execute(management_token) when is_binary(management_token) do
    with {:ok, participant} <- ParticipantQueries.get_by_token(management_token),
         :ok <- ensure_live(participant),
         {:ok, meeting} <- MeetingQueries.get_meeting(participant.meeting_id),
         :ok <- ensure_meeting_live(meeting),
         :ok <- Policy.can_cancel_meeting?(meeting) do
      cancel_seat(meeting, participant)
    end
  end

  defp ensure_live(%{cancelled_at: nil}), do: :ok
  defp ensure_live(_participant), do: {:error, :already_cancelled}

  defp ensure_meeting_live(%{status: "cancelled"}), do: {:error, :already_cancelled}
  defp ensure_meeting_live(_meeting), do: :ok

  defp cancel_seat(meeting, participant) do
    transaction_result =
      Repo.transaction(fn ->
        # Serialises with book_seat/3, which locks the same row before it
        # counts seats, so a booker cannot slip in mid-cancellation. It also
        # serialises two concurrent cancels of this *same* seat: both can
        # pass the pre-transaction `ensure_live/1` check off the same stale
        # read before either commits. Re-checking liveness here, after the
        # lock and against a fresh read, is what stops the loser from
        # blindly re-cancelling a participant the winner already cancelled
        # and re-running the last-leaver side effects (resurrecting the
        # calendar event the winner just deleted, re-notifying the
        # organiser) against a meeting that has already been finalised.
        GroupMeetingQueries.lock_for_update(meeting.id)

        with {:ok, current} <- ParticipantQueries.get(participant.id),
             :ok <- ensure_live(current) do
          case ParticipantQueries.cancel(current) do
            {:ok, cancelled} -> cancelled
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, cancelled} ->
        after_commit(meeting, cancelled)

      {:error, :already_cancelled} ->
        Logger.info("Seat already cancelled by a concurrent request",
          meeting_id: meeting.id,
          participant_id: participant.id
        )

        {:error, :already_cancelled}

      {:error, reason} ->
        Logger.error("Failed to cancel seat",
          meeting_id: meeting.id,
          participant_id: participant.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # `SeatRelease.release/1` decides under the meeting row lock whether this
  # was the last seat. The leaver's own confirmation is sent either way; when
  # the meeting goes with them it carries `notify_organizer: false`, because
  # the meeting-level cancellation notifies the organiser already.
  defp after_commit(meeting, cancelled) do
    publish_seat_change(meeting)

    case SeatRelease.release(meeting) do
      {:ok, :meeting_cancelled} ->
        Events.seat_cancelled(meeting, cancelled, notify_organizer: false)
        {:ok, :meeting_cancelled}

      {:ok, :seats_remain} ->
        CalendarJobs.schedule_job(meeting, "update")
        Events.seat_cancelled(meeting, cancelled, notify_organizer: true)
        {:ok, :seat_cancelled}

      {:error, :release_check_failed} ->
        # The emptiness check failed, not the meeting's status transition —
        # `release/1`'s own transaction rolled back on failure, so the
        # meeting is still confirmed either way. That is exactly the
        # `:seats_remain` state as far as this seat's own cancellation is
        # concerned: the leaver still needs their calendar event refreshed
        # and the organiser still needs telling. `SeatRelease` has already
        # alerted on the check itself failing.
        CalendarJobs.schedule_job(meeting, "update")
        Events.seat_cancelled(meeting, cancelled, notify_organizer: true)
        {:ok, :seat_cancelled}
    end
  end

  # A freed seat changes both the seat count on the slot and, for the last
  # leaver, the slot's availability itself. Neither is visible until the
  # cached availability for the organiser is dropped.
  defp publish_seat_change(meeting) do
    AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)
    SeatBroadcast.broadcast_seat_change(meeting.meeting_type_id)
    :ok
  end
end
