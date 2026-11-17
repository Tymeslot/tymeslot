defmodule Tymeslot.Bookings.SeatRelease do
  @moduledoc """
  Cancels a group meeting once its last seat has been released, unless the
  host planned it (`Tymeslot.Meetings.PlannedSessions`): a planned session
  stays when it empties.

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

  A paid seat hold (`Tymeslot.Meetings.SeatHolds`) that lapses or fails
  asks the same question through `release_hold/2`, which settles the
  meeting with `settle_after_hold/1`: a slot only holds created goes away
  as an unpaid booking does, by expiring.
  """

  require Logger

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Repo

  @type settlement ::
          {:ok, :kept} | {:ok, :expired, Meeting.t()} | {:ok, :cancelled, Meeting.t()}

  @typedoc """
  A released hold, for `announce_released/1` once its transaction commits:
  the meeting as locked before the release, whether this release freed the
  hold (`false` when it was no longer held), and how the meeting settled.
  """
  @type hold_release :: %{
          hold_id: binary(),
          meeting: Meeting.t() | nil,
          released?: boolean(),
          settled: settlement()
        }

  @doc """
  Cancels `meeting` when no live participant remains on it and no seat is
  held for a booker paying for one (`Tymeslot.Meetings.SeatHolds`).

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
      is_nil(locked) or locked.status == :cancelled ->
        {:ok, :seats_remain}

      # A session the host planned exists because it was planned, not because
      # somebody booked it, so it stays open when its last participant leaves
      # (`Tymeslot.Meetings.PlannedSessions`).
      locked.planned ->
        {:ok, :seats_remain}

      ParticipantQueries.count_live_for_meeting(meeting.id) > 0 ->
        {:ok, :seats_remain}

      # A booker mid-checkout holds a seat as a participant does: the
      # meeting stays for them, and settles once the hold converts or is
      # released (`settle_after_hold/1`).
      SeatHolds.seats_held(meeting.id) > 0 ->
        {:ok, :seats_remain}

      true ->
        flip_to_cancelled(locked)
    end
  end

  defp flip_to_cancelled(meeting) do
    attrs = %{status: :cancelled, cancelled_at: DateTime.truncate(Clock.utc_now(), :second)}

    case MeetingQueries.update_meeting_status(meeting, attrs) do
      {:ok, cancelled} -> {:ok, {:cancelled, cancelled}}
      {:error, _changeset} = error -> error
    end
  end

  @doc """
  Settles the group meeting `meeting_id` once a seat hold on it has been
  converted or released, inside the caller's transaction and under the
  meeting's row lock:

    * seats still held or a live participant, or a session the host
      planned: `{:ok, :kept}`;
    * nobody left on a meeting still awaiting payment (a slot only holds
      ever took): expired as an unpaid booking is, `{:ok, :expired, meeting}`,
      for `Checkout.announce_expired/1` after commit;
    * nobody left on a confirmed meeting: cancelled as `cancel_if_emptied/1`
      cancels it, `{:ok, :cancelled, meeting}`, for
      `Cancel.finalise_cancellation/1` after commit.

  A caller that releases the hold in the same transaction locks the meeting
  first (`release_hold/2` does).
  """
  @spec settle_after_hold(binary()) :: settlement() | {:error, Ecto.Changeset.t()}
  def settle_after_hold(meeting_id) when is_binary(meeting_id) do
    meeting_id
    |> GroupMeetingQueries.lock_for_update()
    |> settle_locked()
  end

  defp settle_locked(nil), do: {:ok, :kept}
  defp settle_locked(%Meeting{planned: true}), do: {:ok, :kept}

  defp settle_locked(%Meeting{} = meeting) do
    cond do
      SeatHolds.seats_held(meeting.id) > 0 -> {:ok, :kept}
      ParticipantQueries.count_live_for_meeting(meeting.id) > 0 -> {:ok, :kept}
      meeting.status == :awaiting_payment -> expire_held(meeting)
      meeting.status == :confirmed -> cancel_emptied(meeting)
      true -> {:ok, :kept}
    end
  end

  defp expire_held(meeting) do
    case Checkout.expire_held_meeting(meeting.id) do
      {:ok, :expired, expired} -> {:ok, :expired, expired}
      {:ok, :unchanged} -> {:ok, :kept}
      {:error, _changeset} = error -> error
    end
  end

  defp cancel_emptied(meeting) do
    case flip_to_cancelled(meeting) do
      {:ok, {:cancelled, cancelled}} -> {:ok, :cancelled, cancelled}
      {:error, _changeset} = error -> error
    end
  end

  @doc """
  Releases `hold` for `reason` and settles its meeting
  (`settle_after_hold/1`), inside the caller's transaction. Locks the
  meeting before the hold, after any payment row the caller holds. A hold
  no longer held keeps its first outcome; its meeting is settled all the
  same. Pass the result to `announce_released/1` once committed.
  """
  @spec release_hold(SeatHoldSchema.t(), SeatHoldSchema.release_reason()) ::
          {:ok, hold_release()} | {:error, Ecto.Changeset.t()}
  def release_hold(%SeatHoldSchema{} = hold, reason) do
    meeting = GroupMeetingQueries.lock_for_update(hold.meeting_id)
    {:ok, released} = SeatHolds.release(hold, reason)

    case settle_after_hold(hold.meeting_id) do
      {:error, _changeset} = error ->
        error

      settled ->
        {:ok,
         %{
           hold_id: hold.id,
           meeting: meeting,
           released?: released != :unchanged,
           settled: settled
         }}
    end
  end

  @doc """
  Releases a hold whose payment never completed (its checkout could not be
  opened, or its outcome never arrived), as one transaction: its pending
  payment failed first (`Checkout.fail_seat_payment/1`), then the hold
  released as `:failed` (`release_hold/2`), and announced once committed.
  """
  @spec release_unpaid_hold(SeatHoldSchema.t()) :: {:ok, hold_release()} | {:error, term()}
  def release_unpaid_hold(%SeatHoldSchema{} = hold) do
    result =
      Repo.transaction(fn ->
        with {:ok, _payment} <- Checkout.fail_seat_payment(hold.id),
             {:ok, released} <- release_hold(hold, :failed) do
          released
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, released} <- result do
      :ok = announce_released(released)
      result
    end
  end

  @doc """
  Announces a released hold (`release_hold/2`) once its transaction has
  committed: the meeting it settled expired or cancelled with the usual
  effects, the slot's seats offered again, and, when this release freed the
  hold, the booker's payment page told the hold is gone. A hold no longer
  held was announced by whoever settled it first (a conversion, or an
  earlier release), so nothing goes to its topic a second time.
  """
  @spec announce_released(hold_release()) :: :ok
  def announce_released(%{hold_id: hold_id, meeting: meeting, settled: settled} = release) do
    case settled do
      {:ok, :expired, expired} -> Checkout.announce_expired(expired)
      {:ok, :cancelled, cancelled} -> Cancel.finalise_cancellation(cancelled)
      {:ok, :kept} -> :ok
    end

    if meeting, do: SeatEffects.broadcast_and_invalidate(meeting)
    if release.released?, do: SeatHolds.broadcast(hold_id, :expired)
    :ok
  end
end
