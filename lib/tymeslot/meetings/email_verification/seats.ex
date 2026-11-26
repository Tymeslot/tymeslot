defmodule Tymeslot.Meetings.EmailVerification.Seats do
  @moduledoc """
  The email verification gate for a seat on a group meeting; reached through
  `Tymeslot.Meetings.EmailVerification`.

  A held seat (`verification_deadline_at` set, `email_verified_at` not) takes
  capacity on its slot but is shown to nobody. The slot it sits on is either
  live already (another seat counts, or the host planned the session) or
  itself held, `:awaiting_verification`, when no seat on it counts yet.

  Every transition here locks the slot row before touching a seat, as
  `Tymeslot.Bookings.CancelSeat` does, so a verification, an expiry and a
  cancellation on the same slot are serialised, and "was this the slot's last
  held seat?" is answered against a stable roster.
  """

  require Logger

  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.SlotActivation
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias Tymeslot.Repo

  @disowned "Unverified seat disowned by its booker"

  @doc """
  Counts a held seat once its booker has confirmed their address.

  In one transaction under the slot's row lock, the seat is marked verified
  and owes what an ungated seat owes on booking
  (`Tymeslot.Bookings.SlotActivation`): on a held slot it is the first seat
  to count, so the slot is confirmed and gets its calendar event, reminders
  and video room; on a live slot the calendar event is updated to add the
  attendee. Either way the seat's confirmation and the organiser's seat
  email go out, and the integrations hear of the booking once it commits.

  Returns the slot in the tuple. A seat past its deadline is released
  instead (`{:error, :expired}`), as is one whose slot no longer occupies its
  time, and one whose meeting type was deleted, deactivated or made
  series-only while it was held, held slot or live, as
  `EmailVerification.verify/1` releases such a booking. Group types cannot be
  invitation-only, so no invitation check applies. `{:error, :not_scheduled}`
  means the seat's work could not be queued, and `{:error, :slot_void}` that
  a pending reschedule request has voided the slot's time; either way the
  seat is still held and the booker may try again. A seat no longer
  held is answered for as stored: `{:ok, :already_verified, slot}` while it
  stands verified, including on a slot a pending reschedule request has
  voided, as a one-to-one booking in that state is already confirmed,
  `{:error, :expired}` once released or cancelled, or once its slot no
  longer occupies its time.
  """
  @spec verify_seat(Participant.t()) :: EmailVerification.verify_result()
  def verify_seat(%Participant{} = seat) do
    now = Clock.utc_now()

    cond do
      not held?(seat) -> answer_as_stored(seat)
      EmailVerification.deadline_reached?(seat, now) -> expire_instead(seat)
      true -> seat |> count_seat(now) |> verify_outcome(seat)
    end
  end

  defp held?(seat), do: Participant.live?(seat) and Participant.unverified?(seat)

  defp count_seat(seat, now) do
    Repo.transaction(fn ->
      with {:ok, slot} <- lock_slot(seat),
           :ok <- ensure_live(slot, seat, now),
           :ok <- ensure_still_wanted(slot),
           {:ok, verified} <-
             ParticipantQueries.transition_from_unverified(
               seat.id,
               DateTime.truncate(now, :second)
             ),
           {:ok, pending} <- SlotActivation.activate_seat_in_transaction(slot, verified),
           {:ok, live_slot} <- MeetingQueries.get_meeting(slot.id) do
        {live_slot, verified, pending}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp verify_outcome({:ok, {slot, verified, pending}}, _seat) do
    EmailVerificationJobs.cancel_seat(verified)
    :ok = Activation.after_commit(pending)
    Telemetry.booking_created()
    SeatEffects.broadcast_and_invalidate(slot)
    Logger.info("Seat email verified", meeting_id: slot.id, participant_id: verified.id)

    {:ok, :verified, slot}
  end

  # Lost a race with another exit (a second click, the expiry job).
  defp verify_outcome({:error, :not_awaiting_verification}, seat), do: answer_as_stored(seat)

  # A pending reschedule request voids the slot's time without releasing its
  # seats, so the seat is neither confirmed onto a time that does not hold
  # nor released: it stays held, to be verified should the request be
  # withdrawn, and lapses at its deadline otherwise.
  defp verify_outcome({:error, :slot_void}, seat) do
    Logger.info("Seat verification refused: its slot awaits a new time",
      meeting_id: seat.meeting_id,
      participant_id: seat.id
    )

    {:error, :slot_void}
  end

  # The slot was cancelled, expired or deleted while the seat was held; the
  # seat went with it (`Tymeslot.Bookings.SeatRelease`).
  defp verify_outcome({:error, reason}, _seat) when reason in [:slot_gone, :not_found],
    do: {:error, :expired}

  # As for a one-to-one booking (`EmailVerification.verify/1`): a seat whose
  # meeting type was deleted, deactivated or made series-only while it was
  # held is released, silently, rather than confirmed onto a type that would
  # refuse it were it booked now.
  defp verify_outcome({:error, :no_longer_wanted}, seat), do: expire_instead(seat)

  defp verify_outcome({:error, :slot_taken}, seat) do
    Logger.warning("Seat verification refused: the slot was taken",
      meeting_id: seat.meeting_id,
      participant_id: seat.id
    )

    expire_instead(seat)
  end

  defp verify_outcome({:error, reason}, seat) do
    Logger.error("Seat verification rolled back: its effects could not be scheduled",
      meeting_id: seat.meeting_id,
      participant_id: seat.id,
      reason: LogFormat.reason(reason)
    )

    {:error, :not_scheduled}
  end

  # The expiry can lose to a verification that passed its own deadline check
  # an instant earlier, so the answer comes from the row, not the attempt.
  defp expire_instead(seat) do
    case expire_seat(seat) do
      {:ok, _expired} -> {:error, :expired}
      {:error, :not_awaiting_verification} -> answer_as_stored(seat)
    end
  end

  # A pending reschedule request leaves a verified seat standing, so it reads
  # as confirmed, as `EmailVerification.verify/1` answers a one-to-one
  # booking awaiting a new time.
  defp answer_as_stored(seat) do
    with {:ok, %Participant{email_verified_at: %DateTime{}} = current} <-
           ParticipantQueries.get(seat.id),
         {:ok, slot} <- MeetingQueries.get_meeting(seat.meeting_id),
         standing when standing in [:live, :slot_void] <-
           EmailVerification.seat_standing(slot, current) do
      {:ok, :already_verified, slot}
    else
      _gone_released_or_never_verified -> {:error, :expired}
    end
  end

  @doc """
  Releases a held seat whose deadline has passed.

  Silent by design: no email, webhook or calendar change, since nobody but
  the booker ever learned of the seat. Its capacity is freed. A held slot
  left with no held seat is voided with it, so its time is free again
  (`:expired`, or `:cancelled` for one the organiser knew of before its last
  confirmed seat left, see `Tymeslot.Bookings.SeatRelease`); a live slot, or
  one still holding another seat, is not touched. A held slot left with only
  seat holds for bookers still paying awaits their payment again
  (`:awaiting_payment`).
  """
  @spec expire_seat(Participant.t()) ::
          {:ok, Participant.t()} | {:error, :not_awaiting_verification}
  def expire_seat(%Participant{} = seat), do: release_held(seat, "Unverified seat released")

  @doc """
  Releases a held seat its booker says they never made ("This wasn't me").

  Exactly `expire_seat/1`, silent, freeing its capacity and voiding a held
  slot left with no held seat; only the log records that the address's owner
  disowned it. A seat has no status of its own, so unlike `release/1` there
  is no `:cancelled` to tell it apart from a lapse.
  """
  @spec release_seat(Participant.t()) ::
          {:ok, Participant.t()} | {:error, :not_awaiting_verification}
  def release_seat(%Participant{} = seat), do: release_held(seat, @disowned)

  @doc """
  `release_seat/1` for a caller running it inside a transaction of its own:
  the same release, voiding a held slot left with no held seat and removing
  the seat's expiry job, but returning the slot and leaving its announcement
  to `announce_released/1`, which the caller runs once that transaction
  commits. Announced any earlier, an open booking page re-reads the slot
  while the seat still holds it uncommitted.
  """
  @spec release_seat_in_transaction(Participant.t()) ::
          {:ok, Meeting.t()} | {:error, :not_awaiting_verification}
  def release_seat_in_transaction(%Participant{} = seat) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    with {:ok, {expired, slot}} <- release_locked(seat, now) do
      EmailVerificationJobs.cancel_seat(expired)
      Logger.info(@disowned, meeting_id: slot.id, participant_id: expired.id)

      {:ok, slot}
    end
  end

  @doc """
  Tells open booking pages and the organiser's availability that a seat on
  `slot` was released; see `release_seat_in_transaction/1`.
  """
  @spec announce_released(Meeting.t()) :: :ok
  def announce_released(%Meeting{} = slot), do: SeatEffects.broadcast_and_invalidate(slot)

  @doc """
  Releases every held seat on a slot that is going away or moving: a host
  cancelling the whole meeting, or moving a session they planned to a time
  its held bookers never picked.

  Silent like `expire_seat/1`, and its expiry jobs go with it, so a held
  booker's link then reads expired. Runs inside the caller's transaction,
  after the caller has locked or updated the slot row, so the lock order
  (slot, then its seats) holds.
  """
  @spec release_all_held(binary()) :: :ok
  def release_all_held(meeting_id) do
    now = DateTime.truncate(Clock.utc_now(), :second)
    {_count, seat_ids} = ParticipantQueries.cancel_unverified_for_meeting(meeting_id, now)
    Enum.each(seat_ids, &EmailVerificationJobs.cancel_seat(%{id: &1}))
  end

  defp release_held(seat, message) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    released =
      Repo.transaction(fn ->
        case release_locked(seat, now) do
          {:ok, expired_and_slot} -> expired_and_slot
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {expired, slot}} <- released do
      SeatEffects.broadcast_and_invalidate(slot)
      EmailVerificationJobs.cancel_seat(expired)
      Logger.info(message, meeting_id: slot.id, participant_id: expired.id)

      {:ok, expired}
    end
  end

  # Writes nothing when it fails, so a caller's own transaction survives it.
  defp release_locked(seat, now) do
    with {:ok, slot} <- lock_slot(seat),
         {:ok, expired} <- ParticipantQueries.cancel_unverified(seat.id, now) do
      {:ok, {expired, void_if_unheld(slot, now)}}
    else
      {:error, _not_held_or_gone} -> {:error, :not_awaiting_verification}
    end
  end

  # Under the slot's lock, so a seat booked or verified on it meanwhile is
  # either counted here or waits for this to commit.
  #
  # A slot that never counted expires, a hold nobody but its bookers saw. One
  # that was confirmed before its last confirmed seat left
  # (`Tymeslot.Bookings.SeatRelease`) still carries `email_verified_at`: the
  # organiser was told of it and then that it was cancelled, so it ends
  # `:cancelled`, which keeps it in their history and out of the prune of
  # unverified holds.
  #
  # Seats held for bookers still paying (`Tymeslot.Meetings.SeatHolds`) keep
  # the slot too: their payment must still find it. With no held seat left
  # it awaits payment again, as a slot only holds took does, so it settles
  # with its holds (`SeatRelease.settle_after_hold/1`).
  defp void_if_unheld(%Meeting{status: :awaiting_verification} = slot, now) do
    cond do
      ParticipantQueries.count_seats_held(slot.id) > 0 ->
        slot

      SeatHolds.seats_held(slot.id) > 0 ->
        {:ok, awaiting_payment} = GroupMeetingQueries.return_to_awaiting_payment(slot)
        awaiting_payment

      true ->
        {:ok, voided} =
          MeetingTransitionQueries.transition_from_awaiting_verification(slot.id,
            status: voided_status(slot),
            cancelled_at: now
          )

        voided
    end
  end

  defp void_if_unheld(slot, _now), do: slot

  defp voided_status(%Meeting{email_verified_at: %DateTime{}}), do: :cancelled
  defp voided_status(_never_counted), do: :expired

  # The checks the booking path makes (`Tymeslot.Bookings.Create`): a type
  # the host has deactivated, or made series-only, would refuse this seat
  # were it booked now. A deleted type nilifies the column; an archived one
  # is still read.
  defp ensure_still_wanted(%{meeting_type_id: type_id, organizer_user_id: user_id})
       when is_integer(type_id) and is_integer(user_id) do
    case MeetingTypes.get_meeting_type(type_id, user_id) do
      %MeetingType{is_active: true} = type ->
        if SeriesSettings.single_allowed?(type), do: :ok, else: {:error, :no_longer_wanted}

      _gone_or_inactive ->
        {:error, :no_longer_wanted}
    end
  end

  defp ensure_still_wanted(_slot), do: {:error, :no_longer_wanted}

  defp lock_slot(seat), do: MeetingQueries.get_meeting_for_update(seat.meeting_id)

  defp ensure_live(slot, seat, now) do
    case EmailVerification.seat_standing(slot, seat, now) do
      :live -> :ok
      :slot_void -> {:error, :slot_void}
      :gone -> {:error, :slot_gone}
    end
  end
end
