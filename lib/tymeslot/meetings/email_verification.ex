defmodule Tymeslot.Meetings.EmailVerification do
  @moduledoc """
  The email verification gate: a booking on a meeting type that requires it is
  held until the attendee confirms their address through an emailed link.

  While held (`:awaiting_verification`) the booking occupies its slot against
  every other booking, but nothing else happens: the organiser learns nothing
  about it until `verify/1` succeeds. No emails, webhooks, calendar event,
  video room, dashboard listing, counts or analytics. Verification then moves
  the booking on exactly as an ungated booking would have gone: confirmed, or
  held for the host's approval.

  Every exit from the gate (verifying, expiring) is a guarded transition,
  `Tymeslot.Meetings.MeetingTransitionQueries.transition_from_awaiting_verification/2`,
  so the exits race one another safely and only one wins.

  A manual-approval type's approval clock starts at verification, not at
  submission: the host is only asked once the attendee has proved the address,
  so the window they are promised runs from that moment
  (`Tymeslot.Meetings.Approval.request_attributes/3`).

  ## Leaving the gate

    * `verify/1`: the attendee confirms. The booking is confirmed (or held for
      approval) and only now does the world hear of it, through
      `Tymeslot.Bookings.Activation`, exactly as an ungated booking would.
      External calendars and booking limits are not checked again: the
      booking won both when it was made, and verification only completes it.
    * `expire/1`: the deadline passed. The slot is freed and nobody is told
      anything; nobody but the attendee ever knew of the booking.
    * `release/1`: the attendee says they did not make the booking. Identical
      to `expire/1` but recorded as `:cancelled`.

  ## Group seats

  A seat on a group meeting goes through the same gate, one seat at a time:
  `verify_seat/1`, `expire_seat/1` and `release_seat/1`, implemented in
  `Tymeslot.Meetings.EmailVerification.Seats`, and `resend_seat/1`. The first seat to be verified
  on a slot held for verification brings the slot to life; the last held seat
  to expire on one voids it. A held slot's own `verification_deadline_at` only
  hides it from the organiser: `expire/1`, `release/1` and `resend/1` refuse a
  group slot, and the sweep never lists one.

  `resend/1` sends the same verification email again while the booking is
  held, `resend_seat/1` while the seat is. Neither moves the deadline. At
  most three resends per booking or seat, so at most four emails including
  the one sent with it; the count lives in `verification_emails_sent`, where
  `nil` means that first email only.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Invitations
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.EmailVerification.Resend
  alias Tymeslot.Meetings.EmailVerification.Seats
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

  # Fixed rather than per meeting type: the verification email promises this
  # window, and the slot is held from everyone else for as long as it runs.
  @hold_minutes 30

  # How long after its deadline a booking that never left the gate is kept
  # before it is deleted. Long enough for a late click on the email link to
  # read "expired" (the token lives two days, so after this it reads
  # "invalid"); short because the organiser never saw the data and the
  # address may not be the attendee's.
  @unverified_retention_hours 24

  @type verify_result ::
          {:ok, :verified, Meeting.t()}
          | {:ok, :already_verified, Meeting.t()}
          | {:error, :expired}
          | {:error, :not_scheduled}
          | {:error, :slot_void}

  # `:slot_void` only for a seat: its slot's time is voided by a pending
  # reschedule request, so nothing was sent or counted.
  @type resend_error ::
          :limit_reached | :expired | :not_awaiting_verification | :not_scheduled | :slot_void

  @doc "Whether bookings on this meeting type must be verified by email."
  @spec required?(MeetingType.t() | map() | nil) :: boolean()
  def required?(%{requires_email_verification: true}), do: true
  def required?(_meeting_type), do: false

  @doc "How long an unverified booking holds its slot, in minutes."
  @spec hold_minutes() :: pos_integer()
  def hold_minutes, do: @hold_minutes

  @doc """
  When a booking made at `requested_at` stops being verifiable.

  Never later than the meeting's own start time: a slot that has begun cannot
  be given away.
  """
  @spec deadline_for(DateTime.t(), DateTime.t()) :: DateTime.t()
  def deadline_for(%DateTime{} = requested_at, %DateTime{} = start_time) do
    hold_end = DateTime.add(requested_at, @hold_minutes * 60, :second)
    earliest = if DateTime.compare(hold_end, start_time) == :lt, do: hold_end, else: start_time

    DateTime.truncate(earliest, :second)
  end

  @doc """
  The attributes a gated booking is created with: held, with its deadline, and
  the approval fields left unstamped until verification.
  """
  @spec gate_attributes(DateTime.t(), DateTime.t()) :: map()
  def gate_attributes(%DateTime{} = now, %DateTime{} = start_time) do
    %{
      status: :awaiting_verification,
      verification_deadline_at: deadline_for(now, start_time),
      approval_requested_at: nil,
      approval_deadline_at: nil
    }
  end

  @doc """
  Completes a held booking once the attendee has confirmed their address.

  The booking moves to `:confirmed`, or to `:awaiting_approval` when its
  meeting type (read now, not at booking) requires approval, and everything
  an ungated booking would have started starts now, in one transaction: the
  calendar event, the video room, the confirmation or request emails and
  the reminders. A verification at or after the deadline releases the
  booking instead, as does one no longer wanted, released silently
  (`{:error, :expired}`) rather than confirmed: one whose meeting type has
  since been deleted, since without the type nobody can say whether the host
  must approve it; one whose type has since become paid, since its bookings
  are confirmed by payment, or a group type, whose bookings take seats; one
  whose type has since been deactivated or made series-only, since a fresh
  booking would be refused there too; and one made through an invitation
  link the host has since revoked. An archived type is still read and its
  settings apply. `{:error, :not_scheduled}` means
  that work could not be queued; the booking is still held and the attendee
  may try again.

  The deadline and the still-wanted checks run inside the transaction, with
  the booking's row locked, so a revocation or a type change that commits
  first is always seen.

  A booking no longer held is answered for as it is stored, not as the
  caller's copy says: `{:ok, :already_verified, meeting}` while it stands,
  and `{:error, :expired}` once released, which also covers a booking
  verified and later cancelled, since its link no longer leads anywhere.
  """
  @spec verify(Meeting.t()) :: verify_result()
  def verify(%Meeting{email_verified_at: %DateTime{}} = meeting), do: answer_as_stored(meeting)

  def verify(%Meeting{} = meeting) do
    if MeetingState.awaiting_verification?(meeting),
      do: meeting |> complete(Clock.utc_now()) |> verify_outcome(meeting),
      else: {:error, :expired}
  end

  # The row lock comes first: a deleted type nilifies `meeting_type_id` on this
  # row, so a deletion either committed before the lock and is read here, or
  # waits for this transaction to finish.
  defp complete(meeting, now) do
    Repo.transaction(fn ->
      with {:ok, held} <- MeetingQueries.get_meeting_for_update(meeting.id),
           {:ok, meeting_type} <- still_wanted(held),
           {:ok, verified} <-
             MeetingTransitionQueries.transition_from_awaiting_verification(
               held.id,
               verified_changes(held, meeting_type, now),
               deadline_after: now
             ),
           {:ok, _scheduled} <- schedule_calendar_event(verified),
           {:ok, pending} <- Activation.activate_in_transaction(verified, with_video_room: true) do
        {verified, pending}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp verified_changes(meeting, meeting_type, now) do
    [email_verified_at: DateTime.truncate(now, :second)] ++
      Map.to_list(Approval.request_attributes(meeting_type, now, meeting.start_time))
  end

  # Whether the booking may still go ahead, with the meeting type whose
  # settings decide how. A deleted type nilifies the column, and without its
  # settings nobody can say whether the host must approve, so the hold is
  # released rather than confirmed past an approval it may have needed. An
  # archived type is still read and its settings apply. A type that has since
  # become paid cannot carry the gate (the type's rules refuse both), and one
  # that has become a group type books seats, not one-to-one meetings:
  # confirming here would skip the payment or the seats, so the hold is
  # released. A type the host has since deactivated, or since made
  # series-only, would refuse the booking were it submitted now
  # (`Tymeslot.Bookings.Create`), so it is not confirmed either; the series
  # rule is read through the same `SeriesSettings.single_allowed?/1` the
  # booking path asks. The host never sees a held booking, so may revoke the
  # invitation link it came through meanwhile; the revocation stands and the
  # hold is released.
  defp still_wanted(meeting) do
    with %MeetingType{is_active: true} = meeting_type <- meeting_type(meeting),
         false <- confirmed_by_other_means?(meeting_type),
         true <- SeriesSettings.single_allowed?(meeting_type),
         false <- invitation_revoked?(meeting) do
      {:ok, meeting_type}
    else
      _type_gone_inactive_changed_or_invitation_revoked -> {:error, :no_longer_wanted}
    end
  end

  defp confirmed_by_other_means?(%MeetingType{payment_required: true}), do: true
  defp confirmed_by_other_means?(meeting_type), do: MeetingType.group?(meeting_type)

  defp invitation_revoked?(%{invitation_id: nil}), do: false
  defp invitation_revoked?(%{invitation_id: id}), do: Invitations.revoked?(id)

  defp meeting_type(%{meeting_type_id: type_id, organizer_user_id: user_id})
       when is_integer(type_id) and is_integer(user_id),
       do: MeetingTypes.get_meeting_type(type_id, user_id)

  defp meeting_type(_meeting), do: nil

  # True for `:awaiting_approval` too: the request writes the host's
  # tentative hold exactly as an ungated approval booking does.
  defp schedule_calendar_event(verified) do
    if MeetingState.expects_calendar_event?(verified),
      do: CalendarJobs.schedule_job(verified, "create"),
      else: {:ok, :not_needed}
  end

  defp verify_outcome({:ok, {verified, pending}}, _meeting) do
    EmailVerificationJobs.cancel(verified)
    :ok = Activation.after_commit(pending)
    Availability.changed(verified.organizer_user_id)
    Telemetry.booking_created()
    Logger.info("Booking email verified", meeting_id: verified.id, status: verified.status)

    {:ok, :verified, verified}
  end

  # The guarded transition refused (another exit won the race, or the
  # deadline has passed), the booking is no longer wanted, or it is gone.
  # Releasing it settles all of these: a booking still held is expired, and
  # one that already left the gate is answered for as stored.
  defp verify_outcome({:error, reason}, meeting)
       when reason in [:not_awaiting_verification, :no_longer_wanted, :not_found],
       do: expire_instead(meeting)

  defp verify_outcome({:error, reason}, meeting) do
    Logger.error("Booking verification rolled back: its effects could not be scheduled",
      meeting_id: meeting.id,
      reason: LogFormat.reason(reason)
    )

    {:error, :not_scheduled}
  end

  # The expiry can lose to a verification that passed its own deadline check
  # an instant earlier, so the answer comes from the row, not the attempt.
  defp expire_instead(meeting) do
    case expire(meeting) do
      {:ok, _expired} -> {:error, :expired}
      {:error, :not_awaiting_verification} -> answer_as_stored(meeting)
    end
  end

  defp answer_as_stored(meeting) do
    with {:ok, %Meeting{email_verified_at: %DateTime{}} = current} <-
           MeetingQueries.get_meeting(meeting.id),
         false <- MeetingState.released_status?(current.status) do
      {:ok, :already_verified, current}
    else
      _gone_released_or_never_verified -> {:error, :expired}
    end
  end

  @doc """
  Whether a held booking or seat can no longer be verified at `now`. The
  deadline itself counts as passed, as it does for the sweep.
  """
  @spec deadline_reached?(Meeting.t() | Participant.t(), DateTime.t()) :: boolean()
  def deadline_reached?(%{verification_deadline_at: %DateTime{} = deadline}, now),
    do: DateTime.compare(now, deadline) != :lt

  def deadline_reached?(_booking_or_seat, _now), do: false

  @doc """
  Where a group seat stands against its slot at `now`; the one rule the
  verification, its emails and its page all read.

    * `:live`: the seat stands (verified, or held with its deadline ahead)
      on a slot that occupies its time.
    * `:slot_void`: the seat stands, but a pending reschedule request has
      voided the slot's time. Nothing is released: a held seat stays held,
      cannot be verified while the request is pending, and still lapses at
      its deadline.
    * `:gone`: the seat was released or cancelled, a held seat's deadline
      has passed, or its slot no longer occupies its time (cancelled,
      expired).
  """
  @spec seat_standing(Meeting.t(), Participant.t(), DateTime.t()) ::
          :live | :slot_void | :gone
  def seat_standing(%Meeting{} = slot, %Participant{} = seat, now \\ Clock.utc_now()) do
    cond do
      not Participant.live?(seat) -> :gone
      Participant.unverified?(seat) and deadline_reached?(seat, now) -> :gone
      slot.status not in MeetingState.occupying() -> :gone
      MeetingState.slot_void?(slot) -> :slot_void
      true -> :live
    end
  end

  @doc "Whether `seat_standing/3` reads `:live`."
  @spec seat_live?(Meeting.t(), Participant.t(), DateTime.t()) :: boolean()
  def seat_live?(%Meeting{} = slot, %Participant{} = seat, now \\ Clock.utc_now()),
    do: seat_standing(slot, seat, now) == :live

  @doc "Counts a held group seat; see `Tymeslot.Meetings.EmailVerification.Seats.verify_seat/1`."
  defdelegate verify_seat(seat), to: Seats

  @doc "Releases a held group seat; see `Tymeslot.Meetings.EmailVerification.Seats.expire_seat/1`."
  defdelegate expire_seat(seat), to: Seats

  @doc "Releases a held group seat its booker disowns; see `Tymeslot.Meetings.EmailVerification.Seats.release_seat/1`."
  defdelegate release_seat(seat), to: Seats

  @doc "`release_seat/1` inside the caller's transaction; see `Tymeslot.Meetings.EmailVerification.Seats.release_seat_in_transaction/1`."
  defdelegate release_seat_in_transaction(seat), to: Seats

  @doc "Announces a seat released in a transaction once it commits; see `Tymeslot.Meetings.EmailVerification.Seats.announce_released/1`."
  defdelegate announce_seat_released(slot), to: Seats, as: :announce_released

  @doc "Releases every held seat on a slot; see `Tymeslot.Meetings.EmailVerification.Seats.release_all_held/1`."
  defdelegate release_all_held(meeting_id), to: Seats

  @doc "Fetches a seat by id, for the booking page's resend; `{:error, :not_found}` once it was pruned."
  @spec fetch_seat(binary()) :: {:ok, Participant.t()} | {:error, :not_found}
  def fetch_seat(id) when is_binary(id), do: ParticipantQueries.get(id)

  @doc """
  Releases a held booking whose deadline has passed.

  Silent by design: no email, webhook, calendar or video call, since none of
  them ever learned of the booking. Only the slot is freed. The booking is
  dated as ended at its deadline (`MeetingState.lapsed_at/2`), however late
  this runs.

  A group slot is refused: it expires only through its seats
  (`expire_seat/1`), whatever its own deadline says.
  """
  @spec expire(Meeting.t()) :: {:ok, Meeting.t()} | {:error, :not_awaiting_verification}
  def expire(%Meeting{} = meeting) do
    ended_at = MeetingState.lapsed_at(meeting.verification_deadline_at, Clock.utc_now())
    release_hold(meeting, :expired, ended_at, "Unverified booking released")
  end

  @disowned "Unverified booking disowned by its attendee"

  @doc """
  Releases a held booking its attendee says they never made.

  Exactly `expire/1`, silent and freeing the slot, but recorded as
  `:cancelled`, since the address's owner disowned it rather than letting it
  lapse.
  """
  @spec release(Meeting.t()) :: {:ok, Meeting.t()} | {:error, :not_awaiting_verification}
  def release(%Meeting{} = meeting),
    do: release_hold(meeting, :cancelled, Clock.utc_now(), @disowned)

  @doc """
  `release/1` for a caller running it inside a transaction of its own: the
  same release, but the organiser's availability is left for the caller to
  announce with `Tymeslot.Availability.changed/1` once that transaction
  commits. Announced any earlier, an open booking page re-reads the slot
  while the hold still stands uncommitted, and keeps it hidden.
  """
  @spec release_in_transaction(Meeting.t()) ::
          {:ok, Meeting.t()} | {:error, :not_awaiting_verification}
  def release_in_transaction(%Meeting{} = meeting),
    do: release_quietly(meeting, :cancelled, Clock.utc_now(), @disowned)

  defp release_hold(%Meeting{} = meeting, _status, _ended_at, _message)
       when meeting.capacity > 1,
       do: {:error, :not_awaiting_verification}

  defp release_hold(meeting, status, ended_at, message) do
    with {:ok, released} <- release_quietly(meeting, status, ended_at, message) do
      Availability.changed(released.organizer_user_id)
      {:ok, released}
    end
  end

  defp release_quietly(meeting, status, ended_at, message) do
    changes = [status: status, cancelled_at: DateTime.truncate(ended_at, :second)]

    with {:ok, released} <-
           MeetingTransitionQueries.transition_from_awaiting_verification(meeting.id, changes) do
      EmailVerificationJobs.cancel(released)
      Logger.info(message, meeting_id: released.id)

      {:ok, released}
    end
  end

  @doc """
  Deletes bookings and group seats that never left the gate, `hours` after
  their deadline.

  Covers both ways out without verifying: expired (`expire/1`,
  `expire_seat/1`) and released (`release/1`). The organiser never saw them,
  so unlike a booking that was once confirmed they are deleted, not
  anonymised; guests go with them.
  Returns the `{count, nil}` of bookings and seats deleted together.
  """
  @spec prune_unverified(non_neg_integer()) :: {non_neg_integer(), nil}
  def prune_unverified(hours \\ @unverified_retention_hours) do
    cutoff = DateTime.add(Clock.utc_now(), -hours, :hour)
    {bookings, _rows} = MeetingQueries.delete_unverified_lapsed_before(cutoff)
    {seats, _rows} = ParticipantQueries.delete_unverified_cancelled_before(cutoff)

    if bookings + seats > 0,
      do: Logger.info("Pruned unverified bookings", deleted_count: bookings, seat_count: seats)

    {bookings + seats, nil}
  end

  @doc """
  How many more times the hold's verification email may be resent, by its
  stored count alone (the deadline and status are `resend/1`'s to judge).
  Zero once the resends are used up.
  """
  @spec resends_left(Meeting.t() | Participant.t()) :: non_neg_integer()
  defdelegate resends_left(hold), to: Resend

  @doc """
  Sends the verification email again, with the same link deadline; see
  `Tymeslot.Meetings.EmailVerification.Resend`. A group slot is refused
  (`:not_awaiting_verification`): its emails belong to its seats
  (`resend_seat/1`).
  """
  @spec resend(Meeting.t()) :: {:ok, Meeting.t()} | {:error, resend_error()}
  def resend(%Meeting{} = meeting) when meeting.capacity > 1,
    do: {:error, :not_awaiting_verification}

  def resend(%Meeting{} = meeting), do: Resend.resend(meeting)

  @doc """
  Sends a held seat's verification email again, as `resend/1` does for a
  booking; see `Tymeslot.Meetings.EmailVerification.Resend`.
  """
  @spec resend_seat(Participant.t()) :: {:ok, Participant.t()} | {:error, resend_error()}
  def resend_seat(%Participant{} = seat), do: Resend.resend(seat)
end
