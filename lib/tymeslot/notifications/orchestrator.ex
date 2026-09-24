defmodule Tymeslot.Notifications.Orchestrator do
  @moduledoc """
  Orchestrates the scheduling and sending of notifications.
  Coordinates between notification rules, recipients, and content building.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.ApprovalJobs

  alias Tymeslot.Notifications.{
    ContentBuilder,
    GuestNotifications,
    Recipients,
    ReminderSchedule,
    SchedulingRules
  }

  @doc """
  Schedules all notifications for a newly created meeting.
  """
  @spec schedule_meeting_notifications(%{atom() => term()}) :: {:ok, atom()} | {:error, term()}
  def schedule_meeting_notifications(meeting) do
    Logger.info("Scheduling notifications for meeting", meeting_id: meeting.id)

    with :ok <- schedule_confirmation_notifications(meeting),
         result <- schedule_reminder_notifications(meeting) do
      case result do
        :ok -> {:ok, :notifications_scheduled}
        {:ok, _result} -> {:ok, :notifications_scheduled}
        error -> error
      end
    else
      {:error, reason} = error ->
        Logger.error("Failed to schedule meeting notifications",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        error
    end
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
          reason: inspect(reason)
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
    recipients = Recipients.determine_recipients(meeting, :confirmation)
    content = ContentBuilder.build_appointment_details(meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content),
         result <- schedule_confirmation_job(meeting.id) do
      case result do
        :ok -> :ok
        {:ok, _result} -> :ok
        error -> error
      end
    end
  end

  @doc """
  Schedules reminder notifications for a meeting.
  """
  @spec schedule_reminder_notifications(%{atom() => term()}) ::
          :ok | {:ok, atom()} | {:error, term()}
  def schedule_reminder_notifications(meeting) do
    # `ReminderSchedule` is the single reader of the meeting's reminder column,
    # legacy shapes included, so what a surface shows a booking reminds with is
    # what is scheduled here.
    reminders = ReminderSchedule.configured(meeting)

    recipients = Recipients.determine_recipients(meeting, :reminder)
    content = ContentBuilder.build_reminder_details(meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      {result, scheduled_any?} = schedule_reminders(meeting, reminders)

      case {result, scheduled_any?} do
        {:ok, true} -> :ok
        {:ok, false} -> {:ok, :reminder_not_scheduled}
        {error, _scheduled} -> error
      end
    end
  end

  @doc """
  Cancels pending reminder-email jobs for a meeting.

  The inverse of `schedule_reminder_notifications/1` — together the two
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
    recipients = Recipients.determine_recipients(meeting, :cancellation)

    with :ok <- Recipients.validate_recipients(recipients) do
      worker_module = get_email_worker_module()

      case worker_module.schedule_cancellation_emails(meeting.id) do
        :ok -> {:ok, :cancellation_scheduled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Sends reschedule notifications immediately, to the host and the booker and
  then to the booking's guests (`GuestNotifications.notify_rescheduled/2`).
  """
  @spec send_reschedule_notifications(%{atom() => term()}, %{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
  def send_reschedule_notifications(updated_meeting, original_meeting) do
    recipients = Recipients.determine_recipients(updated_meeting, :reschedule)
    content = ContentBuilder.build_reschedule_details(updated_meeting, original_meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      # Send immediately via EmailService
      result = send_reschedule_emails(content)
      GuestNotifications.notify_rescheduled(updated_meeting, content)
      result
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
  """
  @spec send_reapproval_notifications(%{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
  def send_reapproval_notifications(%{first_announced_at: nil}), do: {:ok, :not_a_move}

  def send_reapproval_notifications(meeting) do
    recipients = Recipients.determine_recipients(meeting, :reschedule)
    content = ContentBuilder.build_reapproval_details(meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      send_reschedule_emails(content)
    end
  end

  @doc """
  Schedules calendar invitation emails for a list of attendees.

  Enqueues one Oban job per attendee via EmailScheduler. Logs warnings for
  individual scheduling failures but does not abort the remaining attendees.
  """
  @spec schedule_calendar_invitations(pos_integer(), [String.t()], map()) :: :ok
  def schedule_calendar_invitations(_user_id, [], _event_details), do: :ok

  def schedule_calendar_invitations(user_id, attendee_emails, event_details) do
    worker_module = get_email_worker_module()

    Enum.each(attendee_emails, fn email ->
      params = %{
        user_id: user_id,
        attendee_email: email,
        event_title: event_details.title,
        event_uid: event_details.uid,
        event_start_at: DateTime.to_iso8601(event_details.start_at),
        event_end_at: DateTime.to_iso8601(event_details.end_at),
        event_location: event_details[:location],
        event_description: event_details[:description]
      }

      case worker_module.schedule_calendar_invitation(params) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to schedule invitation",
            attendee_email: email,
            reason: reason
          )
      end
    end)
  end

  @doc """
  Schedules a delayed event update notification for all attendees.

  Captures the "before" snapshot of attendee-relevant fields. The Oban job
  fires after 2 minutes, reads the current event state, diffs against the
  snapshot, and sends one email per attendee if changes remain.
  """
  @spec schedule_event_update_notification(pos_integer(), map()) :: :ok
  def schedule_event_update_notification(user_id, original_event) do
    attendee_emails = extract_attendee_emails(original_event.attendees)

    if attendee_emails == [] do
      :ok
    else
      worker_module = get_email_worker_module()

      case worker_module.schedule_event_update_notification(%{
             user_id: user_id,
             event_uid: original_event.uid,
             integration_id: original_event.calendar_integration_id,
             attendee_emails: attendee_emails,
             before_title: original_event.summary,
             before_location: original_event.location,
             before_description: original_event.description,
             before_start_at: original_event.start_at,
             before_end_at: original_event.end_at
           }) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to schedule event update notification",
            event_uid: original_event.uid,
            reason: reason
          )
      end

      :ok
    end
  end

  # Private functions

  defp extract_attendee_emails(nil), do: []

  defp extract_attendee_emails(attendees) do
    attendees
    |> Enum.map(&attendee_email/1)
    |> Enum.filter(& &1)
  end

  # Attendees arrive string-keyed from provider payloads and atom-keyed from
  # in-process callers, so both shapes are answered here once.
  defp attendee_email(%{"email" => email}) when is_binary(email), do: email
  defp attendee_email(%{email: email}) when is_binary(email), do: email
  defp attendee_email(_attendee), do: nil

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

  defp send_reschedule_emails(content) do
    email_service = Config.email_service_module()

    case email_service.send_reschedule_emails(content) do
      {{:ok, _organizer}, {:ok, _attendee}} ->
        {:ok, :reschedules_sent}

      {organizer_result, attendee_result} ->
        Logger.warning("Some reschedule emails may have failed",
          organizer_result: inspect(organizer_result),
          attendee_result: inspect(attendee_result)
        )

        {:ok, :reschedules_partially_sent}
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
