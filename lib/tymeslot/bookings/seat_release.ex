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

  To the organiser and the integrations the meeting is over, exactly as if
  it had been cancelled: the leaving seat's own email and event say so, and
  `finish_return_to_held/1` removes what the confirmed slot had (calendar
  event, video room, reminders, pending room creation). The slot row is
  reset to what a slot that never counted carries: unverified, with a
  verification deadline (its held seats' latest), no video room, and a new
  calendar identity, so that the event a later activation creates is a new
  event rather than the deleted one written again, which a provider keeping
  deleted events by id (Google) refuses.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.VideoSyncWorker

  @doc """
  Cancels `meeting` when no live participant remains on it.

  Returns `{:ok, :meeting_cancelled}` when it cancelled the meeting (having
  run the cancellation side effects), `{:ok, :returned_to_held}` when held
  seats kept it and it is held for verification again (having run
  `finish_return_to_held/1`), `{:ok, :seats_remain}` when someone is
  still on the slot, including the case where a booker took a seat while the
  leaver was committing, and `{:error, :release_check_failed}` when the
  emptiness check itself could not be completed — the meeting's status is
  unchanged in that case (the transaction rolled back), but a caller must not
  read this as "seats remain": that would be reporting an unknown as a known
  answer. Its caller (`CancelSeat.after_commit/2`) handles this alongside
  the other outcomes.
  """
  @spec release(Meeting.t()) ::
          {:ok, :meeting_cancelled | :returned_to_held | :seats_remain}
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
  under `meeting`'s row lock, when no live participant remains on it,
  cancels it, or holds it for verification again when held seats remain
  (see the module doc). The side effects are the caller's, once its
  transaction has committed: `Tymeslot.Bookings.Cancel.finalise_cancellation/1`
  on a `{:cancelled, meeting}`, and `finish_return_to_held/1` on a
  `{:held, meeting}`, which carries the meeting as it was before, still
  naming the calendar event and video room it let go of.

  For a caller whose own transaction must not commit unless the meeting is
  cancelled with it (a seat move that has already treated the old meeting's
  time as free): an `{:error, reason}` is the caller's to roll back.
  """
  @spec cancel_if_emptied(Meeting.t()) ::
          {:ok, {:cancelled, Meeting.t()} | {:held, Meeting.t()} | :seats_remain}
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

      ParticipantQueries.count_live_for_meeting(meeting.id) > 0 ->
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
  room, the reminders, and any room creation not yet run. Each step is
  best effort and never fails the caller, as there.
  """
  @spec finish_return_to_held(Meeting.t()) :: :ok
  def finish_return_to_held(%Meeting{} = confirmed_meeting) do
    Availability.changed(confirmed_meeting.organizer_user_id)
    :ok = Meetings.release_calendar_event(confirmed_meeting)
    release_video_room(confirmed_meeting)
    Jobs.delete_meeting_jobs(VideoRoomWorker, confirmed_meeting.id)
    Events.slot_returned_to_held(confirmed_meeting)
  end

  # A held seat keeps a confirmed slot, held again. A slot with no held seat
  # is cancelled; so is one in any other status, which no live group slot
  # holds in practice, its held seats going with it rather than outliving a
  # slot `SlotActivation` could not bring back.
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

  # A slot that never counted carries no verification stamp, no room and no
  # calendar event; a fresh `calendar_uid` with no `provider_event_id` is
  # what makes the next activation's calendar job a create of a new event.
  # The old event's calendar (`calendar_integration_id`, `calendar_path`)
  # stays, for the job deleting it.
  defp return_to_held(meeting, deadline) do
    changes = [
      email_verified_at: nil,
      verification_deadline_at: deadline,
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
