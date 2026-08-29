defmodule Tymeslot.Notifications.Orchestrator do
  @moduledoc """
  Orchestrates the scheduling and sending of notifications.
  Coordinates between notification rules, recipients, and content building.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.ApprovalJobs
  alias Tymeslot.Notifications.{ContentBuilder, Recipients, SchedulingRules}
  alias Tymeslot.Utils.ReminderUtils

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
  always runs; a failure in any of them is logged and rolled into an overall
  error for the caller.
  """
  @spec schedule_request_notifications(%{atom() => term()}) ::
          {:ok, :notifications_scheduled} | {:error, term()}
  def schedule_request_notifications(meeting) do
    Logger.info("Scheduling booking request notifications", meeting_id: meeting.id)

    results = [
      request_emails: MeetingScheduler.schedule_request_emails(meeting.id),
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
      MeetingScheduler.schedule_approval_nudge(meeting.id, send_at)
    else
      :ok
    end
  end

  @doc """
  Sends the invitee the email closing out a request that will not happen.
  """
  @spec send_request_outcome_notifications(%{atom() => term()}, :declined | :expired) ::
          {:ok, :notifications_scheduled} | {:error, term()}
  def send_request_outcome_notifications(meeting, variant) do
    case MeetingScheduler.schedule_request_outcome(meeting.id, variant) do
      :ok -> {:ok, :notifications_scheduled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels every pending job for a booking request that has been answered.

  Both the nudge and the expiry, together: see `Tymeslot.Meetings.ApprovalJobs`
  for why they are cancelled as one action rather than two.
  """
  @spec cancel_request_notifications(%{atom() => term()}) :: :ok
  def cancel_request_notifications(meeting) do
    :ok = MeetingScheduler.cancel_approval_emails(meeting.id)
    ApprovalJobs.cancel(meeting)
  end

  @doc """
  Schedules confirmation notifications for a meeting.
  """
  @spec schedule_confirmation_notifications(%{atom() => term()}) :: :ok | {:error, term()}
  def schedule_confirmation_notifications(meeting) do
    recipients = Recipients.determine_recipients(meeting, :confirmation)
    content = ContentBuilder.build_appointment_details(meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content),
         result <- schedule_email_job(:confirmation, meeting.id) do
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
    reminders =
      case Map.get(meeting, :reminders) do
        nil ->
          # Legacy meetings without reminders field - derive from legacy fields
          legacy_label = meeting.reminder_time || meeting.default_reminder_time || "30 minutes"
          value = ReminderUtils.parse_reminder_value(legacy_label)
          unit = ReminderUtils.normalize_reminder_unit(legacy_label)
          [%{value: value, unit: unit}]

        reminder_list ->
          normalized = normalize_reminders(reminder_list)
          # Respect empty list as "no reminders" - only default when nil
          normalized
      end

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
  Sends reschedule notifications immediately.
  """
  @spec send_reschedule_notifications(%{atom() => term()}, %{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
  def send_reschedule_notifications(updated_meeting, original_meeting) do
    recipients = Recipients.determine_recipients(updated_meeting, :reschedule)
    content = ContentBuilder.build_reschedule_details(updated_meeting, original_meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      # Send immediately via EmailService
      send_immediate_notifications(:reschedule, content)
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

  defp schedule_email_job(
         notification_type,
         meeting_id,
         schedule_at \\ nil,
         reminder_value \\ nil,
         reminder_unit \\ nil
       ) do
    worker_module = get_email_worker_module()

    case notification_type do
      :confirmation ->
        worker_module.schedule_confirmation_emails(meeting_id)

      :reminder ->
        worker_module.schedule_reminder_emails(
          meeting_id,
          reminder_value,
          reminder_unit,
          schedule_at
        )
    end
  end

  defp send_immediate_notifications(notification_type, content) do
    email_service = Config.email_service_module()

    case notification_type do
      :reschedule ->
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
  end

  # Module getters for dependency injection in tests
  defp get_email_worker_module do
    Application.get_env(:tymeslot, :email_worker_module, Tymeslot.Emails.EmailScheduler)
  end

  defp normalize_reminders(reminders) do
    ReminderUtils.normalize_reminders(reminders)
  end

  defp schedule_reminders(meeting, reminders) do
    results =
      Enum.map(reminders, fn %{value: value, unit: unit} ->
        if SchedulingRules.should_schedule_reminder?(meeting.start_time, value, unit) do
          schedule_at = SchedulingRules.calculate_reminder_time(meeting.start_time, value, unit)

          case schedule_email_job(:reminder, meeting.id, schedule_at, value, unit) do
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
