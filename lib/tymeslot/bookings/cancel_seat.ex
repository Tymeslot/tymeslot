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
    * last leaver beside held seats (bookers yet to verify their address):
      the meeting is held for verification again rather than cancelled, and
      ends for the organiser exactly as a cancelled one does
      (`SeatRelease.finish_return_to_held/1`), while each held seat keeps its
      own deadline. To the leaver and the organiser this reads as the last
      leaver's case.
    * the slot already held by another leaver, whose seat was given up at
      the same moment and whose release ran first: the organiser was told
      then that the meeting is off, so only the leaver is emailed, and the
      held slot has no calendar event to refresh.
    * seats remain: the host calendar event is refreshed so its participant
      list matches the live participants, and both the participant and the
      organiser are emailed.

  A seat-availability broadcast and an availability-cache invalidation are
  published after commit in both cases.

  A seat of a series is also the series' last seat to come when its booker
  gives it up last: the series is then closed (`BookingSeries.maybe_close/1`).
  Giving up every remaining seat of a series at once goes through
  `cancel_in_transaction/1` and `finish/2` instead (`BookingSeries.Cancel`).
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.BookingSeries
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Meetings.SeatLookup
  alias Tymeslot.Notifications.Events.Seats
  alias Tymeslot.Repo

  @doc """
  Cancels the seat behind `management_token`.

  Refuses what `Tymeslot.Meetings.SeatLookup.fetch_cancellable_seat/1`
  refuses: an unknown token (`:not_found`), a seat already given up or moved
  (`:already_cancelled`), a meeting the host cancelled
  (`:meeting_cancelled`), and a meeting under way or over
  (`:meeting_started`, `:meeting_past`).
  """
  @spec execute(String.t()) ::
          {:ok, :seat_cancelled | :meeting_cancelled} | {:error, term()}
  def execute(management_token) when is_binary(management_token) do
    with {:ok, %{participant: participant, meeting: meeting}} <-
           SeatLookup.fetch_cancellable_seat(management_token) do
      meeting
      |> cancel_seat(participant)
      |> close_series(participant)
    end
  end

  @typedoc "A seat given up in the caller's transaction, for `finish/2`."
  @type released :: %{
          meeting: Meeting.t(),
          participant: Participant.t(),
          outcome:
            {:cancelled, Meeting.t()} | {:held, Meeting.t()} | :already_held | :seats_remain
        }

  @doc """
  Gives up `participant`'s seat inside the caller's transaction, under its
  meeting's row lock, and cancels the meeting with it when no live seat
  remains (`SeatRelease.cancel_if_emptied/1`). Refuses, for the caller to
  roll back, what `execute/1` refuses once it holds the lock
  (`:already_cancelled`, `:meeting_cancelled`); the caller has checked the
  meeting has not started.

  Nothing is announced: once the caller's transaction has committed, it
  owes a `finish/2` on each result.
  """
  @spec cancel_in_transaction(Participant.t()) :: {:ok, released()} | {:error, term()}
  def cancel_in_transaction(%Participant{} = participant) do
    locked = GroupMeetingQueries.lock_for_update(participant.meeting_id)

    with {:ok, current} <- ParticipantQueries.get(participant.id),
         :ok <- ensure_live(current),
         :ok <- ensure_meeting_on(locked),
         {:ok, cancelled} <- ParticipantQueries.cancel(current),
         {:ok, outcome} <- SeatRelease.cancel_if_emptied(locked) do
      {:ok, %{meeting: locked, participant: cancelled, outcome: outcome}}
    end
  end

  @doc """
  The side effects of a seat `cancel_in_transaction/1` gave up, once the
  caller's transaction has committed: the availability change, the emptied
  meeting's cancellation or the host event's refresh, and the seat's
  `meeting.cancelled` for integrations. `emails: false` schedules no email,
  for the seat or for a meeting it emptied, for a caller that tells both
  sides itself, and `integrations: false` tells no integration, for a
  caller that tells them itself (`Tymeslot.BookingSeries.Cancel`).
  """
  @spec finish(released(), keyword()) :: :ok
  def finish(%{meeting: meeting, participant: participant, outcome: outcome}, opts \\ []) do
    publish_seat_change(meeting)
    told = Keyword.take(opts, [:emails, :integrations])

    case outcome do
      {:cancelled, cancelled_meeting} ->
        Cancel.finalise_cancellation(cancelled_meeting, told)
        Seats.seat_cancelled(meeting, participant, [slot: :freed] ++ told)

      {:held, confirmed_meeting} ->
        SeatRelease.finish_return_to_held(confirmed_meeting)
        Seats.seat_cancelled(meeting, participant, [slot: :held] ++ told)

      :already_held ->
        Seats.seat_cancelled(meeting, participant, [slot: :already_held] ++ told)

      :seats_remain ->
        CalendarJobs.schedule_job(meeting, "update")
        Seats.seat_cancelled(meeting, participant, told)
    end

    :ok
  end

  defp close_series({:ok, _outcome} = result, %Participant{series_id: series_id})
       when is_binary(series_id) do
    BookingSeries.maybe_close(series_id)
    result
  end

  defp close_series(result, _participant), do: result

  defp ensure_live(%{cancelled_at: nil}), do: :ok
  defp ensure_live(_participant), do: {:error, :already_cancelled}

  defp ensure_meeting_on(%{status: :cancelled}), do: {:error, :meeting_cancelled}
  defp ensure_meeting_on(%{}), do: :ok
  defp ensure_meeting_on(nil), do: {:error, :not_found}

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
        #
        # The meeting itself is re-read under the same lock: a host who
        # cancelled the whole meeting after the pre-transaction read has
        # already told every participant it is off, so this seat is refused
        # as `:meeting_cancelled`, as `RescheduleSeat` refuses a move off it.
        # The seat is checked first, so the loser of two cancels of the last
        # seat still reads as `:already_cancelled` once the winner's release
        # has cancelled the meeting.
        locked = GroupMeetingQueries.lock_for_update(meeting.id)

        with {:ok, current} <- ParticipantQueries.get(participant.id),
             :ok <- ensure_live(current),
             :ok <- ensure_meeting_on(locked) do
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

      {:error, :meeting_cancelled} ->
        Logger.info("Meeting cancelled by the organiser before the seat could be",
          meeting_id: meeting.id,
          participant_id: participant.id
        )

        {:error, :meeting_cancelled}

      {:error, reason} ->
        Logger.error("Failed to cancel seat",
          meeting_id: meeting.id,
          participant_id: participant.id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end

  # `SeatRelease.release/1` decides under the meeting row lock whether this
  # was the last seat. The seat's cancellation emails go out either way; when
  # the meeting goes with them they say so: the organiser's one email about it
  # says the slot is empty and free (`slot: :freed`), or, when held seats keep
  # its time, that the meeting is cancelled (`slot: :held`); when another
  # leaver held it first, that leaver's email was the organiser's, and this
  # seat's goes to its leaver alone (`slot: :already_held`). The meeting-level
  # cancellation of an emptied meeting sends the organiser nothing, see
  # `MeetingEmails`.
  defp after_commit(meeting, cancelled) do
    publish_seat_change(meeting)

    case SeatRelease.release(meeting) do
      {:ok, :meeting_cancelled} ->
        Seats.seat_cancelled(meeting, cancelled, slot: :freed)
        {:ok, :meeting_cancelled}

      {:ok, :returned_to_held} ->
        Seats.seat_cancelled(meeting, cancelled, slot: :held)
        {:ok, :meeting_cancelled}

      {:ok, :already_held} ->
        Seats.seat_cancelled(meeting, cancelled, slot: :already_held)
        {:ok, :meeting_cancelled}

      {:ok, :seats_remain} ->
        CalendarJobs.schedule_job(meeting, "update")
        Seats.seat_cancelled(meeting, cancelled)
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
        Seats.seat_cancelled(meeting, cancelled)
        {:ok, :seat_cancelled}
    end
  end

  # A freed seat changes both the seat count on the slot and, for the last
  # leaver, the slot's availability itself. Neither is visible until the
  # cached availability for the organiser is dropped.
  defp publish_seat_change(meeting) do
    Availability.changed(meeting.organizer_user_id)
    SeatBroadcast.broadcast_seat_change(meeting.meeting_type_id)
    :ok
  end
end
