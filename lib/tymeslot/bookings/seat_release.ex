defmodule Tymeslot.Bookings.SeatRelease do
  @moduledoc """
  Cancels a group meeting once its last seat has been released.

  Both ways of leaving a slot — `Tymeslot.Bookings.CancelSeat` and
  `Tymeslot.Bookings.RescheduleSeat` — end with the same question: was that
  the last live participant, and if so, does the meeting itself go away?

  Asking it outside a lock gets the wrong answer twice over. Two participants
  leaving at once each see the other still live, so neither cancels and a
  confirmed meeting survives with nobody on it; and a booker can take a seat
  in the window between the leaver committing and the meeting being cancelled,
  losing their seat to a cancellation they never saw. `release/1` therefore
  locks the meeting row `FOR UPDATE` and re-counts under that lock, which is
  the same lock `Tymeslot.Meetings.GroupScheduling.book_seat/3` takes before
  it counts seats. Whoever gets there second sees the other's work.

  The status flip commits inside that lock; the side effects of cancelling
  (calendar event, notifications) run afterwards through
  `Tymeslot.Bookings.Cancel.finalise_cancellation/1`, never inside the
  transaction. `CancelSeat` asks after its own commit, through `release/1`;
  `RescheduleSeat` asks inside its move transaction, through
  `cancel_if_emptied/1`, so that a move off a meeting's last seat commits
  with that meeting cancelled or not at all.
  """

  require Logger

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo

  @doc """
  Cancels `meeting` when no live participant remains on it.

  Returns `{:ok, :meeting_cancelled}` when it cancelled the meeting (having
  run the cancellation side effects), `{:ok, :seats_remain}` when someone is
  still on the slot, including the case where a booker took a seat while the
  leaver was committing, and `{:error, :release_check_failed}` when the
  emptiness check itself could not be completed — the meeting's status is
  unchanged in that case (the transaction rolled back), but a caller must not
  read this as "seats remain": that would be reporting an unknown as a known
  answer. Its caller (`CancelSeat.after_commit/2`) handles this alongside
  the other two outcomes.
  """
  @spec release(Meeting.t()) ::
          {:ok, :meeting_cancelled | :seats_remain} | {:error, :release_check_failed}
  def release(%Meeting{} = meeting) do
    result =
      Repo.transaction(fn ->
        case cancel_if_emptied(meeting) do
          {:ok, outcome} -> outcome
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {:cancelled, cancelled_meeting}} ->
        Cancel.finalise_cancellation(cancelled_meeting)
        {:ok, :meeting_cancelled}

      {:ok, :seats_remain} ->
        {:ok, :seats_remain}

      {:error, reason} ->
        # The seat is released either way; an emptied meeting that failed to
        # cancel here is a stale calendar entry, not a lost booking, so this
        # never fails the participant's own action. What it must not do is
        # claim to know the meeting is still populated: the caller
        # (`CancelSeat.after_commit/2`) matches this outcome explicitly,
        # alongside the other two, so reporting it honestly here cannot
        # crash it. A meeting that should
        # have been cancelled and now sits confirmed with nobody on it,
        # blocking the organiser's slot, is exactly the kind of thing that
        # needs a human, since nothing else ever revisits it. `Logger.error`
        # alone is easy to miss in the noise; the admin alert is not.
        Logger.error("Failed to cancel emptied group meeting",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        AdminAlerts.report(:group_meeting_release_failed,
          summary: "Failed to cancel an emptied group meeting; it may be stranded confirmed",
          reason: reason,
          context: %{meeting_id: meeting.id}
        )

        {:error, :release_check_failed}
    end
  end

  @doc """
  The status half of `release/1`, inside the caller's own transaction:
  cancels `meeting` under its row lock when no live participant remains on
  it, and leaves the side effects to the caller, who runs
  `Tymeslot.Bookings.Cancel.finalise_cancellation/1` on the cancelled
  meeting once its transaction has committed.

  For a caller whose own transaction must not commit unless the meeting is
  cancelled with it (a seat move that has already treated the old meeting's
  time as free): an `{:error, reason}` is the caller's to roll back.
  """
  @spec cancel_if_emptied(Meeting.t()) ::
          {:ok, {:cancelled, Meeting.t()} | :seats_remain} | {:error, Ecto.Changeset.t()}
  def cancel_if_emptied(%Meeting{} = meeting) do
    locked = GroupMeetingQueries.lock_for_update(meeting.id)

    cond do
      is_nil(locked) or locked.status == "cancelled" ->
        {:ok, :seats_remain}

      ParticipantQueries.count_live_for_meeting(meeting.id) > 0 ->
        {:ok, :seats_remain}

      true ->
        flip_to_cancelled(locked)
    end
  end

  defp flip_to_cancelled(meeting) do
    attrs = %{status: "cancelled", cancelled_at: DateTime.truncate(Clock.utc_now(), :second)}

    case MeetingQueries.update_meeting_status(meeting, attrs) do
      {:ok, cancelled} -> {:ok, {:cancelled, cancelled}}
      {:error, _changeset} = error -> error
    end
  end
end
