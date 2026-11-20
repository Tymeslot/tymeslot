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
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias Tymeslot.Repo

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
  invitation-only, so no invitation check applies. `{:error, :not_scheduled}` means the seat's work could not be
  queued; it is still held and the booker may try again. A seat no longer
  held is answered for as stored: `{:ok, :already_verified, slot}` while it
  counts, `{:error, :expired}` once released or cancelled.
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
           :ok <- ensure_occupying(slot),
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

  # The slot was cancelled or deleted while the seat was held; the seat
  # went with it (`Tymeslot.Bookings.SeatRelease`).
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

  defp answer_as_stored(seat) do
    with {:ok, %Participant{cancelled_at: nil, email_verified_at: %DateTime{}}} <-
           ParticipantQueries.get(seat.id),
         {:ok, slot} <- MeetingQueries.get_meeting(seat.meeting_id),
         :ok <- ensure_occupying(slot) do
      {:ok, :already_verified, slot}
    else
      _gone_released_or_never_verified -> {:error, :expired}
    end
  end

  @doc """
  Releases a held seat whose deadline has passed.

  Silent by design: no email, webhook or calendar change, since nobody but
  the booker ever learned of the seat. Its capacity is freed. A held slot
  left with no held seat is voided (`:expired`) with it, so its time is free
  again; a live slot, or one still holding another seat, is not touched.
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
  def release_seat(%Participant{} = seat),
    do: release_held(seat, "Unverified seat disowned by its booker")

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
        with {:ok, slot} <- lock_slot(seat),
             {:ok, expired} <- ParticipantQueries.cancel_unverified(seat.id, now) do
          {expired, void_if_unheld(slot, now)}
        else
          {:error, _not_held_or_gone} -> Repo.rollback(:not_awaiting_verification)
        end
      end)

    with {:ok, {expired, slot}} <- released do
      SeatEffects.broadcast_and_invalidate(slot)
      EmailVerificationJobs.cancel_seat(expired)
      Logger.info(message, meeting_id: slot.id, participant_id: expired.id)

      {:ok, expired}
    end
  end

  # Under the slot's lock, so a seat booked or verified on it meanwhile is
  # either counted here or waits for this to commit.
  defp void_if_unheld(%Meeting{status: :awaiting_verification} = slot, now) do
    if ParticipantQueries.count_seats_held(slot.id) == 0 do
      {:ok, voided} =
        MeetingTransitionQueries.transition_from_awaiting_verification(slot.id,
          status: :expired,
          cancelled_at: now
        )

      voided
    else
      slot
    end
  end

  defp void_if_unheld(slot, _now), do: slot

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

  defp ensure_occupying(slot) do
    if slot.status in MeetingState.occupying() and not MeetingState.slot_void?(slot),
      do: :ok,
      else: {:error, :slot_gone}
  end
end
