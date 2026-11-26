defmodule Tymeslot.Emails.EmailScheduler.SeatScheduler do
  @moduledoc """
  Schedules the per-seat emails of a group booking via Oban.

  Each participant's copy of an email is its own job, unique per seat and per
  logical email (`schedule_seat_email/5`), so one recipient's failure or retry
  never holds up or duplicates another's. That covers the seat's own
  confirmation, cancellation and reschedule, and each participant's share of
  the whole-meeting cancellation, reminder, session move and reschedule
  request that a meeting-level job dispatches.
  """

  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Notifications.Events.Seats
  alias Tymeslot.Workers.EmailWorker

  # The per-seat action names live in `Tymeslot.Emails.EmailActions` with
  # every other action; call sites name them by atom.
  defdelegate seat_action(seat_action), to: EmailActions

  @doc """
  Schedules a single-seat email job.

  One job per `(action, meeting_id, participant_id)` plus whatever names
  one logical email among several of the same action for the same seat
  (`extra_keys`, each a key of `extra_args`): the shared shape behind every
  per-seat email action (confirmation, cancellation, reschedule, and the
  whole-meeting cancellation/reminder/reschedule-request fan-outs), so each
  recipient retries independently of the others and a different action for
  the same participant can never collide with this one. `extra_args` carries
  whatever the action needs beyond the two ids (e.g. `slot_freed`, the
  moved-from seat, or the reminder interval).

  The uniqueness covers completed jobs too, which is the point: a dispatcher
  re-run must not send a seat its email a second time. So anything that can
  legitimately send the same action to the same seat twice must say which
  email it is in `extra_keys`. A meeting with reminders at one hour and at 15
  minutes sends two different reminders, keyed by their offset; a host's
  second reschedule request is a second email, keyed by when it was made.
  `unique_overrides` replaces any of these unique options for an action that
  needs a narrower guarantee (see `schedule_seat_session_moved/3`).

  The uniqueness window is wider than the usual 5 minutes deliberately: a
  seat job that hits an open mail circuit breaker snoozes for the breaker's
  recovery window plus jitter (up to ~330 seconds — see
  `Tymeslot.Workers.TransactionalEmailDelivery`), and a meeting-level
  dispatcher retried after its own circuit-open snooze re-runs this function
  for every participant again. A 5-minute window would have already elapsed
  by the time either of those wake up, so the just-inserted (or just
  completed) per-seat job would no longer read as a duplicate and this would
  insert a second one — re-sending to a participant who already got their
  email instead of the harmless no-op re-dispatch is meant to be.
  """
  @spec schedule_seat_email(String.t(), term(), term(), map(), [atom()], keyword()) ::
          :ok | {:error, term()}
  def schedule_seat_email(
        action,
        meeting_id,
        participant_id,
        extra_args \\ %{},
        extra_keys \\ [],
        unique_overrides \\ []
      ) do
    extra_args
    |> Map.merge(%{
      "action" => action,
      "meeting_id" => meeting_id,
      "participant_id" => participant_id
    })
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique:
        Keyword.merge(
          [
            # 1 hour — comfortably past the ~330s worst-case circuit-open
            # snooze on either the seat job itself or the meeting-level
            # dispatcher that re-runs this. See the @doc above.
            period: 3600,
            fields: [:args, :queue],
            keys: [:action, :meeting_id, :participant_id | extra_keys]
          ],
          unique_overrides
        )
    )
    |> Helpers.insert(meeting_id: meeting_id, participant_id: participant_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the confirmation emails for a single group-booking seat.
  """
  @spec schedule_seat_confirmation_emails(term(), term()) :: :ok | {:error, term()}
  def schedule_seat_confirmation_emails(meeting_id, participant_id),
    do: schedule_seat_email(seat_action(:seat_confirmation), meeting_id, participant_id)

  @doc """
  Schedules the organiser's email that a group slot they were told had been
  cancelled is going ahead after all: `participant_id` is the seat that
  brought it back (`Tymeslot.Bookings.SlotActivation`).
  """
  @spec schedule_seat_slot_revived_email(term(), term()) :: :ok | {:error, term()}
  def schedule_seat_slot_revived_email(meeting_id, participant_id),
    do: schedule_seat_email(seat_action(:seat_slot_revived), meeting_id, participant_id)

  @doc """
  Schedules the verification email for one held seat of a group meeting.
  `send` numbers it, so a resend is not swallowed by the first job.
  """
  @spec schedule_seat_verification_email(term(), term(), pos_integer()) ::
          :ok | {:error, term()}
  def schedule_seat_verification_email(meeting_id, participant_id, send \\ 1)
      when is_integer(send) and send > 0 do
    schedule_seat_email(
      seat_action(:seat_email_verification),
      meeting_id,
      participant_id,
      %{"send" => send},
      [:send]
    )
  end

  @doc """
  Schedules the cancellation emails for a single group-booking seat. `slot`
  says what the seat's leaving did to its slot
  (`t:Tymeslot.Notifications.Events.Seats.slot_outcome/0`), carried as
  `"slot_freed"` (the meeting was cancelled with it), `"slot_held"` (held
  seats still occupy its time) and `"organizer_told"` (another leaver had
  already ended it for the organiser, who is sent nothing).
  """
  @spec schedule_seat_cancellation_emails(term(), term(), Seats.slot_outcome()) ::
          :ok | {:error, term()}
  def schedule_seat_cancellation_emails(meeting_id, participant_id, slot) do
    schedule_seat_email(seat_action(:seat_cancellation), meeting_id, participant_id, %{
      "slot_freed" => slot != :goes_ahead,
      "slot_held" => slot == :held,
      "organizer_told" => slot == :already_held
    })
  end

  @doc """
  Schedules the reschedule emails for a single group-booking seat.

  `participant_id` is the seat at its new time; `old_participant_id` is the
  cancelled row it moved from, whose own calendar entry (UID, revision and
  time) the job cancels for the participant and their guests. A seat move
  never rewrites that row, so it is read when the job runs.
  `old_slot` says what the move did to the old slot, carried as
  `schedule_seat_cancellation_emails/3` carries it, under `"old_slot_freed"`
  and `"old_slot_held"`.
  """
  @spec schedule_seat_reschedule_emails(term(), term(), term(), Seats.slot_outcome()) ::
          :ok | {:error, term()}
  def schedule_seat_reschedule_emails(
        meeting_id,
        participant_id,
        old_participant_id,
        old_slot
      ) do
    schedule_seat_email(seat_action(:seat_reschedule), meeting_id, participant_id, %{
      "old_participant_id" => old_participant_id,
      "old_slot_freed" => old_slot != :goes_ahead,
      "old_slot_held" => old_slot == :held
    })
  end

  @doc """
  Schedules one live participant's copy of a whole-meeting cancellation.

  Dispatched (one call per live participant) from the meeting-level
  cancellation job instead of sending inline, so a failure on one participant
  cannot discard the notification to the rest.
  """
  @spec schedule_seat_meeting_cancellation_email(term(), term()) :: :ok | {:error, term()}
  def schedule_seat_meeting_cancellation_email(meeting_id, participant_id),
    do: schedule_seat_email(seat_action(:seat_meeting_cancellation), meeting_id, participant_id)

  @doc """
  Schedules one live participant's reminder.

  Dispatched per live participant from the meeting-level reminder job, for
  the reason given at `schedule_seat_meeting_cancellation_email/2`, and
  dropped unsent once the meeting has started (`relevant_until`).
  """
  @spec schedule_seat_reminder_email(term(), term(), term(), term(), DateTime.t() | nil) ::
          :ok | {:error, term()}
  def schedule_seat_reminder_email(
        meeting_id,
        participant_id,
        reminder_value,
        reminder_unit,
        relevant_until
      ) do
    schedule_seat_email(
      seat_action(:seat_reminder),
      meeting_id,
      participant_id,
      %{
        "reminder_value" => reminder_value,
        "reminder_unit" => reminder_unit,
        "relevant_until" => EmailActions.relevant_until(relevant_until)
      },
      [:reminder_value, :reminder_unit]
    )
  end

  @doc """
  Schedules one live participant's notice that the host moved their planned
  session (`Tymeslot.Meetings.SessionMove`). `from` is the previous start,
  as ISO 8601, which the email names.

  One notice per seat is pending at a time. A move made while the previous
  move's notice has not yet run (`available` or `scheduled`) folds into that
  notice: it keeps its `from`, the time the participant last heard of, and
  the email reads the current time when it sends, so A to B to C sends one
  email saying "previously A". Once a notice has started running (or has
  run), a further move is a new email from the time that notice announced.
  """
  @spec schedule_seat_session_moved(term(), term(), String.t()) :: :ok | {:error, String.t()}
  def schedule_seat_session_moved(meeting_id, participant_id, from) do
    schedule_seat_email(
      seat_action(:seat_session_moved),
      meeting_id,
      participant_id,
      %{"from" => from},
      [],
      states: [:available, :scheduled]
    )
  end

  @doc """
  Schedules one live participant's reschedule request.

  Dispatched per live participant from the meeting-level reschedule-request
  job, for the reason given at `schedule_seat_meeting_cancellation_email/2`.

  `requested_at` (the meeting's `reschedule_requested_at`, as ISO 8601, or
  `nil`) names the request: a re-run of the same dispatch is a duplicate, a
  later request is a new email. Dropped unsent once the request can no longer
  be answered, judged when it runs
  (`Tymeslot.Notifications.Email.RescheduleRequestEmails.check_answerable/1`).
  """
  @spec schedule_seat_reschedule_request(term(), term(), String.t() | nil) ::
          :ok | {:error, term()}
  def schedule_seat_reschedule_request(meeting_id, participant_id, requested_at) do
    schedule_seat_email(
      seat_action(:seat_reschedule_request),
      meeting_id,
      participant_id,
      %{"requested_at" => requested_at},
      [:requested_at]
    )
  end
end
