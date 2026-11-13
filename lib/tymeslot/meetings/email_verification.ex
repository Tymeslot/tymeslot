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
  `Tymeslot.Meetings.MeetingQueries.transition_from_awaiting_verification/2`,
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

  `resend/1` sends the same verification email again while the booking is
  held. It never moves the deadline. At most three resends per booking, so at
  most four emails including the one sent with the booking; the count lives
  in `verification_emails_sent`, where `nil` means that first email only.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType
  alias Tymeslot.Repo

  # Fixed rather than per meeting type: the verification email promises this
  # window, and the slot is held from everyone else for as long as it runs.
  @hold_minutes 30

  # Resends after the email sent with the booking; see the moduledoc.
  @max_resends 3

  @type verify_result ::
          {:ok, :verified, Meeting.t()}
          | {:ok, :already_verified, Meeting.t()}
          | {:error, :expired}
          | {:error, :not_scheduled}

  @type resend_error ::
          :limit_reached | :expired | :not_awaiting_verification | :not_scheduled

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
  booking instead. `{:error, :not_scheduled}` means that work could not be
  queued; the booking is still held and the attendee may try again.
  """
  @spec verify(Meeting.t()) :: verify_result()
  def verify(%Meeting{email_verified_at: %DateTime{}} = meeting),
    do: {:ok, :already_verified, meeting}

  def verify(%Meeting{} = meeting) do
    now = Clock.utc_now()

    cond do
      not MeetingState.awaiting_verification?(meeting) -> {:error, :expired}
      deadline_reached?(meeting, now) -> expire_instead(meeting)
      true -> meeting |> complete(now) |> verify_outcome(meeting)
    end
  end

  defp complete(meeting, now) do
    changes =
      [email_verified_at: DateTime.truncate(now, :second)] ++
        Map.to_list(Approval.request_attributes(meeting_type(meeting), now, meeting.start_time))

    Repo.transaction(fn ->
      with {:ok, verified} <-
             MeetingQueries.transition_from_awaiting_verification(meeting.id, changes),
           {:ok, _scheduled} <- schedule_calendar_event(verified),
           {:ok, pending} <- Activation.activate_in_transaction(verified, with_video_room: true) do
        {verified, pending}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A deleted meeting type nilifies the column; an archived one is not
  # returned. Either way the booking proceeds without approval.
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

  # Lost a race with another exit (a second click, the expiry job): answer
  # for the row as it now stands.
  defp verify_outcome({:error, :not_awaiting_verification}, meeting) do
    case MeetingQueries.get_meeting(meeting.id) do
      {:ok, %Meeting{email_verified_at: %DateTime{}} = current} ->
        {:ok, :already_verified, current}

      _gone_or_released ->
        {:error, :expired}
    end
  end

  defp verify_outcome({:error, :slot_taken}, meeting) do
    Logger.warning("Booking verification refused: the slot was taken",
      meeting_id: meeting.id,
      start_time: meeting.start_time
    )

    expire_instead(meeting)
  end

  defp verify_outcome({:error, reason}, meeting) do
    Logger.error("Booking verification rolled back: its effects could not be scheduled",
      meeting_id: meeting.id,
      reason: LogFormat.reason(reason)
    )

    {:error, :not_scheduled}
  end

  defp expire_instead(meeting) do
    expire(meeting)
    {:error, :expired}
  end

  # The deadline itself counts as passed, as it does for the sweep.
  defp deadline_reached?(%{verification_deadline_at: %DateTime{} = deadline}, now),
    do: DateTime.compare(now, deadline) != :lt

  defp deadline_reached?(_meeting, _now), do: false

  @doc """
  Releases a held booking whose deadline has passed.

  Silent by design: no email, webhook, calendar or video call, since none of
  them ever learned of the booking. Only the slot is freed.
  """
  @spec expire(Meeting.t()) :: {:ok, Meeting.t()} | {:error, :not_awaiting_verification}
  def expire(%Meeting{} = meeting),
    do: release_hold(meeting, :expired, "Unverified booking released")

  @doc """
  Releases a held booking its attendee says they never made.

  Exactly `expire/1`, silent and freeing the slot, but recorded as
  `:cancelled`, since the address's owner disowned it rather than letting it
  lapse.
  """
  @spec release(Meeting.t()) :: {:ok, Meeting.t()} | {:error, :not_awaiting_verification}
  def release(%Meeting{} = meeting),
    do: release_hold(meeting, :cancelled, "Unverified booking disowned by its attendee")

  defp release_hold(meeting, status, message) do
    changes = [status: status, cancelled_at: DateTime.truncate(Clock.utc_now(), :second)]

    with {:ok, released} <-
           MeetingQueries.transition_from_awaiting_verification(meeting.id, changes) do
      Availability.changed(released.organizer_user_id)
      EmailVerificationJobs.cancel(released)
      Logger.info(message, meeting_id: released.id)

      {:ok, released}
    end
  end

  @doc """
  Sends the verification email again, with the same link deadline.

  Allowed while the booking is held and its deadline ahead, at most
  #{@max_resends} times per booking. The count and the email job commit
  together, so a resend that could not be queued (`:not_scheduled`) costs the
  attendee nothing. A resend at or after the deadline releases the booking.
  """
  @spec resend(Meeting.t()) :: {:ok, Meeting.t()} | {:error, resend_error()}
  def resend(%Meeting{} = meeting) do
    now = Clock.utc_now()

    counted =
      Repo.transaction(fn ->
        with {:ok, counted} <-
               MeetingQueries.count_verification_email(meeting.id, now, @max_resends + 1),
             :ok <-
               EmailScheduler.schedule_verification_email(
                 counted.id,
                 counted.verification_emails_sent
               ) do
          counted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    resend_outcome(counted, meeting, now)
  end

  defp resend_outcome({:ok, counted}, _meeting, _now) do
    Logger.info("Booking verification email resent",
      meeting_id: counted.id,
      send: counted.verification_emails_sent
    )

    {:ok, counted}
  end

  defp resend_outcome({:error, :refused}, meeting, now) do
    case MeetingQueries.get_meeting(meeting.id) do
      {:ok, current} -> resend_refusal(current, now)
      {:error, :not_found} -> {:error, :not_awaiting_verification}
    end
  end

  defp resend_outcome({:error, reason}, meeting, _now) do
    Logger.error("Booking verification email could not be resent",
      meeting_id: meeting.id,
      reason: LogFormat.reason(reason)
    )

    {:error, :not_scheduled}
  end

  defp resend_refusal(meeting, now) do
    cond do
      not MeetingState.awaiting_verification?(meeting) -> {:error, :not_awaiting_verification}
      deadline_reached?(meeting, now) -> expire_instead(meeting)
      true -> {:error, :limit_reached}
    end
  end
end
