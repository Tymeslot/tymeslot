defmodule Tymeslot.Notifications.Orchestrator do
  @moduledoc """
  Orchestrates the scheduling and sending of notifications.
  Coordinates between notification rules, recipients, and content building.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.ApprovalJobs

  alias Tymeslot.Notifications.{
    GuestNotifications,
    Recipients,
    ReminderSchedule,
    SchedulingRules
  }

  alias Tymeslot.Repo

  @doc """
  Schedules all notifications for a newly created meeting: the confirmation
  and the reminders.

  Both always run and each failure is logged; any failure is returned, keyed
  by the step that failed. The caller runs this in the transaction that
  claims the meeting's announcement and rolls it back on an error, so the
  booking is announced with both or with neither, and is retried whole.
  """
  @spec schedule_meeting_notifications(%{atom() => term()}) ::
          {:ok, :notifications_scheduled} | {:error, term()}
  def schedule_meeting_notifications(meeting) do
    Logger.info("Scheduling notifications for meeting", meeting_id: meeting.id)

    results = [
      confirmation: schedule_confirmation_notifications(meeting),
      reminders: schedule_reminder_notifications(meeting)
    ]

    errors =
      for {step, {:error, reason}} <- results do
        Logger.error("Failed to schedule meeting notifications",
          meeting_id: meeting.id,
          step: step,
          reason: LogFormat.reason(reason)
        )

        {step, reason}
      end

    if errors == [], do: {:ok, :notifications_scheduled}, else: {:error, errors}
  end

  @doc """
  Schedules the emails a held booking produces, and the nudge that follows.

  Deliberately not `schedule_meeting_notifications/1`: no reminders are
  scheduled here. Reminding an invitee about a meeting nobody has agreed to
  would contradict the acknowledgement they just received, and the reminders
  are scheduled in full once the host approves.

  The three steps are scheduled independently rather than as a `with` chain:
  the expiry has a cron backstop but the nudge does not, so a failure in the
  request email must not leave the nudge (or the expiry) unarmed. Every step
  always runs and every failure is logged, but only `request_emails` and
  `approval_nudge` can roll into the overall error returned to the caller:
  `ApprovalJobs.schedule_expiry/1` always returns `:ok` because the 15-minute
  expiry sweep is a backstop for a failed insert, so a scheduling failure
  there degrades punctuality rather than correctness and is deliberately not
  surfaced as an error.
  """
  @spec schedule_request_notifications(%{atom() => term()}, keyword()) ::
          {:ok, :notifications_scheduled} | {:error, term()}
  def schedule_request_notifications(meeting, opts \\ []) do
    Logger.info("Scheduling booking request notifications", meeting_id: meeting.id)

    results = [
      request_emails:
        EmailScheduler.schedule_request_emails(
          meeting.id,
          Keyword.take(opts, [:previous_start_time])
        ),
      approval_nudge: schedule_approval_nudge(meeting),
      expiry: ApprovalJobs.schedule_expiry(meeting)
    ]

    errors =
      for {step, {:error, reason}} <- results do
        Logger.error("Failed to schedule booking request notification step",
          meeting_id: meeting.id,
          step: step,
          reason: LogFormat.reason(reason)
        )

        {step, reason}
      end

    if errors == [] do
      {:ok, :notifications_scheduled}
    else
      {:error, errors}
    end
  end

  # Halfway through the window, so a host who missed the first email still has
  # as long again to act. A request whose deadline has already passed, or which
  # has no deadline recorded, gets no nudge: there is nothing left to save.
  defp schedule_approval_nudge(%{approval_deadline_at: nil}), do: :ok

  defp schedule_approval_nudge(meeting) do
    requested_at = meeting.approval_requested_at || Clock.utc_now()
    seconds_remaining = DateTime.diff(meeting.approval_deadline_at, requested_at)

    if seconds_remaining > 0 do
      send_at = DateTime.add(requested_at, div(seconds_remaining, 2), :second)
      EmailScheduler.schedule_approval_nudge(meeting.id, send_at)
    else
      :ok
    end
  end

  @doc """
  Sends the invitee the email closing out a request that will not happen.

  When the request was a reschedule of a confirmed booking that lapsed, the
  booking itself is gone, and the host is told as well: nobody declined
  anything, so nothing else would tell them.
  """
  @spec send_request_outcome_notifications(%{atom() => term()}, :declined | :expired) ::
          {:ok, :notifications_scheduled} | {:error, term()}
  def send_request_outcome_notifications(meeting, variant) do
    with :ok <- EmailScheduler.schedule_request_outcome(meeting.id, variant),
         :ok <- maybe_schedule_host_expiry_notice(meeting, variant) do
      {:ok, :notifications_scheduled}
    end
  end

  defp maybe_schedule_host_expiry_notice(%{first_announced_at: %DateTime{}} = meeting, :expired),
    do: EmailScheduler.schedule_reschedule_request_expired(meeting.id)

  defp maybe_schedule_host_expiry_notice(_meeting, _variant), do: :ok

  @doc """
  Cancels every pending job for a booking request that has been answered.

  Both the nudge and the expiry, together: see `Tymeslot.Meetings.ApprovalJobs`
  for why they are cancelled as one action rather than two.
  """
  @spec cancel_request_notifications(%{atom() => term()}) :: :ok
  def cancel_request_notifications(meeting) do
    :ok = EmailScheduler.cancel_approval_emails(meeting.id)
    ApprovalJobs.cancel(meeting)
  end

  # Schedules confirmation notifications for a meeting.
  defp schedule_confirmation_notifications(meeting) do
    with_sendable(meeting, :confirmation, fn ->
      case schedule_confirmation_job(meeting.id) do
        :ok -> :ok
        {:ok, _result} -> :ok
        error -> error
      end
    end)
  end

  # A meeting missing what its emails need (a legacy row without an attendee
  # name, say) can never be emailed, however often it is retried, so it is
  # logged and reported as `{:ok, :not_sendable}` rather than as an error: an
  # error here rolls the booking back for a retry, which only an enqueue
  # that failed can be helped by.
  defp with_sendable(meeting, step, fun) do
    case Recipients.validate(meeting) do
      :ok ->
        fun.()

      {:error, reason} ->
        Logger.error("Meeting cannot be emailed, nothing scheduled",
          meeting_id: meeting.id,
          step: step,
          reason: reason
        )

        {:ok, :not_sendable}
    end
  end

  @doc """
  Schedules reminder notifications for a meeting.

  `replace: true`, for a meeting that moved, first clears the meeting's
  pending reminder jobs, in one transaction with the new ones: a reminder now
  too late for a meeting moved closer, or one no longer configured, is
  skipped and must not fire at its old time, and a failed insert must not
  leave the meeting with no reminder at all. A new meeting has nothing to
  clear, so it skips that query.
  """
  @spec schedule_reminder_notifications(%{atom() => term()}, keyword()) ::
          :ok | {:ok, atom()} | {:error, term()}
  def schedule_reminder_notifications(meeting, opts \\ []) do
    # `ReminderSchedule` is the single reader of the meeting's reminder column,
    # legacy shapes included, so what a surface shows a booking reminds with is
    # what is scheduled here.
    reminders = ReminderSchedule.configured(meeting)

    with_sendable(meeting, :reminders, fn ->
      if Keyword.get(opts, :replace, false),
        do: replace_reminders(meeting, reminders),
        else: pin_reminders(meeting, reminders)
    end)
  end

  defp replace_reminders(meeting, reminders) do
    transaction =
      Repo.transaction(fn ->
        result =
          with :ok <- cancel_reminder_notifications(meeting),
               do: pin_reminders(meeting, reminders)

        with {:error, _reason} = error <- result, do: Repo.rollback(error)
      end)

    case transaction do
      {:ok, result} -> result
      {:error, error} -> error
    end
  end

  defp pin_reminders(meeting, reminders) do
    case schedule_reminders(meeting, reminders) do
      {:ok, true} -> :ok
      {:ok, false} -> {:ok, :reminder_not_scheduled}
      {error, _scheduled} -> error
    end
  end

  @doc """
  Cancels pending reminder-email jobs for a meeting.

  The inverse of `schedule_reminder_notifications/2` — together the two
  functions are the only place reminder jobs are created or removed. Every
  transition that changes whether a meeting has a valid future slot
  (cancellation, an organizer reschedule request, or rebooking after one)
  calls whichever of the two it means directly: callers already know which
  side they want, so there is no reconciling wrapper here.
  """
  @spec cancel_reminder_notifications(%{atom() => term()}) :: :ok | {:error, term()}
  def cancel_reminder_notifications(meeting) do
    worker_module = get_email_worker_module()
    worker_module.cancel_reminder_emails(meeting.id)
  end

  @doc """
  Schedules cancellation notifications via EmailScheduler.
  """
  @spec send_cancellation_notifications(%{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
  def send_cancellation_notifications(meeting) do
    with :ok <- Recipients.validate(meeting, :recipients) do
      worker_module = get_email_worker_module()

      case worker_module.schedule_cancellation_emails(meeting.id) do
        :ok -> {:ok, :cancellation_scheduled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Schedules the confirmation email job for one seat on a group meeting.
  """
  @spec schedule_seat_confirmation(%{atom() => term()}, %{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
  def schedule_seat_confirmation(meeting, participant) do
    worker_module = get_email_worker_module()

    case worker_module.schedule_seat_confirmation_emails(meeting.id, participant.id) do
      :ok -> {:ok, :seat_confirmation_scheduled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Schedules the cancellation email job for one seat on a group meeting.
  """
  @spec schedule_seat_cancellation(%{atom() => term()}, %{atom() => term()}, boolean()) ::
          {:ok, atom()} | {:error, term()}
  def schedule_seat_cancellation(meeting, participant, slot_freed?) do
    worker_module = get_email_worker_module()

    case worker_module.schedule_seat_cancellation_emails(
           meeting.id,
           participant.id,
           slot_freed?
         ) do
      :ok -> {:ok, :seat_cancellation_scheduled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Schedules the reschedule email job for one seat on a group meeting:
  `participant` is the seat at its new time, `old_participant` the seat it
  moved from.
  """
  @spec schedule_seat_reschedule(
          %{atom() => term()},
          %{atom() => term()},
          %{atom() => term()},
          boolean()
        ) :: {:ok, atom()} | {:error, term()}
  def schedule_seat_reschedule(meeting, participant, old_participant, old_slot_freed?) do
    worker_module = get_email_worker_module()

    case worker_module.schedule_seat_reschedule_emails(
           meeting.id,
           participant.id,
           old_participant.id,
           old_slot_freed?
         ) do
      :ok -> {:ok, :seat_reschedule_scheduled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Schedules the reschedule notices to the host, the booker and the booking's
  guests, after resetting the guests' answers, which applied to the previous
  time.

  The notices go out from a retrying email job
  (`Tymeslot.Notifications.Email.RescheduleEmails`), like every other
  booking email, so a mail outage delays them rather than losing them, and
  the reschedule does not wait on the mail provider. The job carries the time
  the booking moved from, which the meeting row no longer holds, and `opts`
  (`moved_by: :host` for a move the host made in their own calendar).
  """
  @spec send_reschedule_notifications(%{atom() => term()}, %{atom() => term()}, keyword()) ::
          {:ok, atom()} | {:error, term()}
  def send_reschedule_notifications(updated_meeting, original_meeting, opts \\ []) do
    with :ok <- Recipients.validate(updated_meeting) do
      GuestNotifications.reset_for_new_time(updated_meeting)
      schedule_reschedule_job(updated_meeting, original_meeting, opts)
    end
  end

  @doc """
  Sends the reschedule notices for a booking whose new time the host has just
  approved.

  A reschedule of a confirmed booking on a meeting type requiring approval
  holds the new time until the host answers, so the move is only final — and
  only announced as such — on approval. Such a booking already had its
  confirmation (`Activation` leaves it alone because the sent flags are still
  set), and to both sides it is a move of a meeting they already have, so it
  goes out as the reschedule notice with an updated calendar entry rather than
  a second "new booking" confirmation. The time it was moved from is not kept
  past the request emails, so these notices carry the new time alone.

  A first approval (no `first_announced_at`) sends nothing here: the regular
  confirmation announces it.

  Scheduled like `send_reschedule_notifications/2`, from a retrying email job
  that also writes to the guests who had been invited.
  """
  @spec send_reapproval_notifications(%{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
  def send_reapproval_notifications(%{first_announced_at: nil}), do: {:ok, :not_a_move}

  def send_reapproval_notifications(meeting) do
    with :ok <- Recipients.validate(meeting) do
      schedule_reschedule_job(meeting, nil)
    end
  end

  # Private functions

  defp schedule_confirmation_job(meeting_id) do
    get_email_worker_module().schedule_confirmation_emails(meeting_id)
  end

  defp schedule_reminder_job(meeting_id, schedule_at, reminder_value, reminder_unit) do
    get_email_worker_module().schedule_reminder_emails(
      meeting_id,
      reminder_value,
      reminder_unit,
      schedule_at
    )
  end

  defp schedule_reschedule_job(meeting, original_meeting, opts \\ []) do
    case get_email_worker_module().schedule_reschedule_emails(meeting, original_meeting, opts) do
      :ok -> {:ok, :reschedules_scheduled}
      {:error, _reason} = error -> error
    end
  end

  # Module getters for dependency injection in tests
  defp get_email_worker_module do
    Application.get_env(:tymeslot, :email_worker_module, Tymeslot.Emails.EmailScheduler)
  end

  defp schedule_reminders(meeting, reminders) do
    results =
      Enum.map(reminders, fn %{value: value, unit: unit} ->
        if SchedulingRules.should_schedule_reminder?(meeting.start_time, value, unit) do
          schedule_at = SchedulingRules.calculate_reminder_time(meeting.start_time, value, unit)

          case schedule_reminder_job(meeting.id, schedule_at, value, unit) do
            :ok -> {:ok, true}
            {:ok, _result} -> {:ok, true}
            error -> {error, false}
          end
        else
          Logger.info("Skipping reminder notification - meeting starts too soon",
            meeting_id: meeting.id,
            reminder: "#{value} #{unit}"
          )

          {:ok, false}
        end
      end)

    # Check if any failed
    error = Enum.find(results, &match?({{:error, _reason}, _sent}, &1))

    if error do
      {elem(error, 0), Enum.any?(results, &elem(&1, 1))}
    else
      {:ok, Enum.any?(results, &elem(&1, 1))}
    end
  end
end
