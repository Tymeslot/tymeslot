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

  ## Held seats outlive the last counting one

  A seat awaiting its booker's email verification is not live in the sense
  above: nobody but its booker knows of it. When the last live seat leaves a
  slot that still holds such seats, the slot is not cancelled, since that
  would void a held booker's link inside their own window because of
  somebody else. It is held for verification again (`:awaiting_verification`,
  as a slot whose only seats are held always is), and each held seat keeps
  its own deadline: the first to be verified brings the slot back to life
  (`Tymeslot.Bookings.SlotActivation`), and the last to lapse or be
  released voids it (`Tymeslot.Meetings.EmailVerification.expire_seat/1`).
  A seat verifying meanwhile waits on the same row lock, so it finds the
  slot either still confirmed or already held.

  Two leavers whose seat cancellations both committed before either asked
  find the slot held by whichever asked first: the second finds it
  `:awaiting_verification` and leaves it be (`:already_held`), since a held
  slot ends only through its held seats. The meeting was already over for
  the organiser, told so by the first leaver's email, so nothing more is
  owed to them or to the calendar for the second.

  To the organiser and the integrations the meeting is over, exactly as if
  it had been cancelled: the leaving seat's own email and event say so, and
  `finish_return_to_held/1` removes what the confirmed slot had (calendar
  event, video room, reminders, pending room creation). The slot row is
  reset to what a held slot carries: a verification deadline (its held
  seats' latest), no video room, and a new calendar identity, so that the
  event a later activation creates is a new event rather than the deleted
  one written again, which a provider keeping deleted events by id (Google)
  refuses. A pending reschedule request is cleared with the rest: it asked
  the confirmed guests, now gone, for a new time, and left standing it would
  void the slot's time, so that no held seat could be verified. The slot
  keeps its `email_verified_at`, the record that the organiser knew of the
  meeting: its status hides it while held, and should its last held seat
  lapse it ends as the cancelled meeting it was to them, in their history,
  rather than as a hold nobody saw.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.Workers.RescheduleRequestExpiryWorker
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Jobs
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.VideoSyncWorker

  @type settlement ::
          {:ok, :kept}
          | {:ok, :expired, Meeting.t()}
          | {:ok, :cancelled, Meeting.t()}
          | {:ok, :held, Meeting.t()}

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
  run the cancellation side effects), `{:ok, :returned_to_held}` when held
  seats kept it and it is held for verification again (having run
  `finish_return_to_held/1`), `{:ok, :already_held}` when another leaver
  had held it already (see the module doc), `{:ok, :seats_remain}` when someone is
  still on the slot, including the case where a booker took a seat while the
  leaver was committing, and `{:error, :release_check_failed}` when the
  emptiness check itself could not be completed — the meeting's status is
  unchanged in that case (the transaction rolled back), but a caller must not
  read this as "seats remain": that would be reporting an unknown as a known
  answer. Its caller (`CancelSeat.after_commit/2`) handles this alongside
  the other outcomes.
  """
  @spec release(Meeting.t()) ::
          {:ok, :meeting_cancelled | :returned_to_held | :already_held | :seats_remain}
          | {:error, :release_check_failed}
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

      {:ok, {:held, confirmed_meeting}} ->
        finish_return_to_held(confirmed_meeting)
        {:ok, :returned_to_held}

      {:ok, remains} when remains in [:already_held, :seats_remain] ->
        {:ok, remains}

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
  under `meeting`'s row lock, when no live participant remains on it,
  cancels it, or holds it for verification again when held seats remain
  (see the module doc). The side effects are the caller's, once its
  transaction has committed: `Tymeslot.Bookings.Cancel.finalise_cancellation/1`
  on a `{:cancelled, meeting}`, and `finish_return_to_held/1` on a
  `{:held, meeting}`, which carries the meeting as it was before, still
  naming the calendar event and video room it let go of. A slot already
  held for verification is left to its held seats (`:already_held`), with
  nothing for the caller to finish.

  For a caller whose own transaction must not commit unless the meeting is
  cancelled with it (a seat move that has already treated the old meeting's
  time as free): an `{:error, reason}` is the caller's to roll back.
  """
  @spec cancel_if_emptied(Meeting.t()) ::
          {:ok, {:cancelled, Meeting.t()} | {:held, Meeting.t()} | :already_held | :seats_remain}
          | {:error, Ecto.Changeset.t() | :not_confirmed}
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

      # Held by another leaver whose release ran first: it ends when its
      # last held seat lapses or is released
      # (`Tymeslot.Meetings.EmailVerification.expire_seat/1`), never here.
      locked.status == :awaiting_verification ->
        {:ok, :already_held}

      ParticipantQueries.count_live_for_meeting(meeting.id) > 0 ->
        {:ok, :seats_remain}

      # A booker mid-checkout holds a seat as a participant does: the
      # meeting stays for them, and settles once the hold converts or is
      # released (`settle_after_hold/1`).
      SeatHolds.seats_held(meeting.id) > 0 ->
        {:ok, :seats_remain}

      true ->
        vacate(locked, ParticipantQueries.latest_held_deadline(meeting.id))
    end
  end

  @doc """
  The side effects of a slot `cancel_if_emptied/1` held for verification
  again, once the caller's transaction has committed. `confirmed_meeting` is
  the slot as it was before (the `{:held, meeting}` outcome), so the jobs
  enqueued here still name its calendar event and video room.

  What `Tymeslot.Bookings.Cancel.finalise_cancellation/1` undoes for a
  cancelled slot, bar the announcement, which is the leaving seat's (see the
  module doc): the organiser's availability, the calendar event, the video
  room, the reminders, any room creation not yet run, and the expiry of a
  reschedule request the slot no longer carries. Each step is
  best effort and never fails the caller, as there.
  """
  @spec finish_return_to_held(Meeting.t()) :: :ok
  def finish_return_to_held(%Meeting{} = confirmed_meeting) do
    Availability.changed(confirmed_meeting.organizer_user_id)
    :ok = Meetings.release_calendar_event(confirmed_meeting)
    release_video_room(confirmed_meeting)
    Jobs.delete_meeting_jobs(VideoRoomWorker, confirmed_meeting.id)
    Jobs.delete_meeting_jobs(RescheduleRequestExpiryWorker, confirmed_meeting.id)
    Events.slot_returned_to_held(confirmed_meeting)
  end

  # A held seat keeps a confirmed slot, held again. A slot with no held seat
  # is cancelled. A group slot is only ever confirmed here, as
  # `cancel_if_emptied/1` leaves a held one to its seats; a slot in any other
  # status is cancelled too, its held seats going with it rather than
  # outliving a slot `SlotActivation` could not bring back.
  defp vacate(%Meeting{status: :confirmed} = slot, %DateTime{} = deadline),
    do: return_to_held(slot, deadline)

  defp vacate(slot, _deadline) do
    :ok = EmailVerification.release_all_held(slot.id)
    flip_to_cancelled(slot)
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
      for `announce_released/1` after commit;
    * nobody left on a confirmed meeting: cancelled as `cancel_if_emptied/1`
      cancels it, `{:ok, :cancelled, meeting}`, for
      `Cancel.finalise_cancellation/1` after commit, or, when seats awaiting
      email verification remain, held for verification again,
      `{:ok, :held, meeting}` (the meeting as it was), for
      `finish_return_to_held/1` after commit.

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
    case vacate(meeting, ParticipantQueries.latest_held_deadline(meeting.id)) do
      {:ok, {:cancelled, cancelled}} -> {:ok, :cancelled, cancelled}
      {:ok, {:held, confirmed}} -> {:ok, :held, confirmed}
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
      # A hold-created meeting that expires had no booker but the hold's,
      # who hears on the hold's topic below; the slot is offered again by
      # `broadcast_and_invalidate/1`.
      {:ok, :expired, _expired} -> :ok
      {:ok, :cancelled, cancelled} -> Cancel.finalise_cancellation(cancelled)
      {:ok, :held, confirmed} -> finish_return_to_held(confirmed)
      {:ok, :kept} -> :ok
    end

    if meeting, do: SeatEffects.broadcast_and_invalidate(meeting)
    if release.released?, do: SeatHolds.broadcast(hold_id, :expired)
    :ok
  end

  # A held slot carries no room and no calendar event; a fresh
  # `calendar_uid` with no `provider_event_id` is what makes the next
  # activation's calendar job a create of a new event. The old event's
  # calendar (`calendar_integration_id`, `calendar_path`) stays, for the job
  # deleting it, and `email_verified_at` stays as the module doc says.
  defp return_to_held(meeting, deadline) do
    changes = [
      verification_deadline_at: deadline,
      reschedule_requested_at: nil,
      calendar_uid: UUID.generate(),
      provider_event_id: nil,
      meeting_url: nil,
      video_room_id: nil,
      video_provider: nil,
      organizer_video_url: nil,
      attendee_video_url: nil,
      video_room_enabled: false,
      video_room_created_at: nil,
      video_room_expires_at: nil
    ]

    with {:ok, _held} <-
           MeetingTransitionQueries.transition_to_awaiting_verification(meeting.id, changes) do
      {:ok, {:held, meeting}}
    end
  end

  defp release_video_room(%Meeting{video_room_id: nil}), do: :ok
  defp release_video_room(%Meeting{organizer_user_id: nil}), do: :ok

  defp release_video_room(meeting) do
    case VideoSyncWorker.release(meeting) do
      {:ok, _scheduled} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue video room release for a slot held again",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
