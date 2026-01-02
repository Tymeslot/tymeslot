defmodule Tymeslot.Emails.EmailService do
  @moduledoc """
  Main email service for sending various types of emails.
  """

  @behaviour Tymeslot.Emails.EmailServiceBehaviour

  require Logger

  alias Tymeslot.Infrastructure.{CircuitBreaker, Retry}
  alias Tymeslot.Mailer

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmationAttendee,
    AppointmentConfirmationOrganizer,
    AppointmentReminderAttendee,
    AppointmentReminderOrganizer,
    CalendarSyncError,
    ContactForm,
    EmailChangeConfirmed,
    EmailChangeNotification,
    EmailChangeVerification,
    EmailVerification,
    PasswordReset,
    RescheduleRequest
  }

  alias Tymeslot.Emails.Shared.MjmlEmail

  alias Swoosh.Email

  @doc """
  Sends an appointment confirmation email to the organizer.
  """
  @spec send_appointment_confirmation_to_organizer(String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_confirmation_to_organizer(organizer_email, appointment_details) do
    organizer_email
    |> AppointmentConfirmationOrganizer.confirmation_email(appointment_details)
    |> deliver()
  end

  @doc """
  Sends an appointment confirmation email to the attendee.
  """
  @spec send_appointment_confirmation_to_attendee(String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_confirmation_to_attendee(attendee_email, appointment_details) do
    attendee_email
    |> AppointmentConfirmationAttendee.confirmation_email(appointment_details)
    |> deliver()
  end

  @doc """
  Sends appointment confirmations to both organizer and attendee.
  """
  @spec send_appointment_confirmations(map()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_appointment_confirmations(appointment_details) do
    Logger.info("Sending appointment confirmations",
      title: appointment_details[:title]
    )

    organizer_result =
      send_appointment_confirmation_to_organizer(
        appointment_details.organizer_email,
        appointment_details
      )

    attendee_result =
      send_appointment_confirmation_to_attendee(
        appointment_details.attendee_email,
        appointment_details
      )

    Logger.info("Appointment confirmations sent",
      organizer_sent: match?({:ok, _}, organizer_result),
      attendee_sent: match?({:ok, _}, attendee_result)
    )

    {organizer_result, attendee_result}
  end

  @doc """
  Sends an appointment reminder email to the organizer.
  """
  @spec send_appointment_reminder_to_organizer(String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_reminder_to_organizer(organizer_email, appointment_details) do
    organizer_email
    |> AppointmentReminderOrganizer.reminder_email(appointment_details)
    |> deliver()
  end

  @doc """
  Sends an appointment reminder email to the attendee.
  """
  @spec send_appointment_reminder_to_attendee(String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_reminder_to_attendee(attendee_email, appointment_details) do
    attendee_email
    |> AppointmentReminderAttendee.reminder_email(appointment_details)
    |> deliver()
  end

  @doc """
  Sends appointment reminders to both organizer and attendee.
  """
  @spec send_appointment_reminders(map()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_appointment_reminders(appointment_details) do
    time_until =
      appointment_details[:time_until] || appointment_details[:reminder_time] || "30 minutes"

    send_appointment_reminders(appointment_details, time_until)
  end

  @doc """
  Sends appointment reminders to both organizer and attendee.
  Takes a time_until parameter (e.g., "30 minutes", "1 hour", "24 hours").
  """
  @spec send_appointment_reminders(map(), String.t()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_appointment_reminders(appointment_details, time_until) do
    Logger.info("Sending appointment reminders",
      title: appointment_details[:title],
      time_until: time_until
    )

    # Add time_until to appointment details
    appointment_details_with_time = Map.put(appointment_details, :time_until, time_until)

    organizer_result =
      send_appointment_reminder_to_organizer(
        appointment_details.organizer_email,
        appointment_details_with_time
      )

    attendee_result =
      send_appointment_reminder_to_attendee(
        appointment_details.attendee_email,
        appointment_details_with_time
      )

    Logger.info("Appointment reminders sent",
      organizer_sent: match?({:ok, _}, organizer_result),
      attendee_sent: match?({:ok, _}, attendee_result)
    )

    {organizer_result, attendee_result}
  end

  @doc """
  Sends a cancellation email. This is the behavior-required function.
  """
  @spec send_appointment_cancellation(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_appointment_cancellation(email, appointment_details) do
    # Determine if this is for organizer or attendee based on email
    if email == appointment_details.organizer_email do
      send_cancellation_email_to_organizer(email, appointment_details)
    else
      send_cancellation_email_to_attendee(email, appointment_details)
    end
  end

  @doc """
  Sends a cancellation email to the attendee.
  """
  @spec send_cancellation_email_to_attendee(String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_cancellation_email_to_attendee(attendee_email, appointment_details) do
    Logger.info("Sending appointment cancellation to attendee",
      title: appointment_details[:title]
    )

    result =
      attendee_email
      |> AppointmentCancellation.cancellation_email_attendee(appointment_details)
      |> deliver()

    Logger.info("Cancellation email sent to attendee",
      sent: match?({:ok, _}, result)
    )

    result
  end

  @doc """
  Sends a cancellation email to the organizer.
  """
  @spec send_cancellation_email_to_organizer(String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_cancellation_email_to_organizer(organizer_email, appointment_details) do
    Logger.info("Sending appointment cancellation to organizer",
      title: appointment_details[:title]
    )

    result =
      organizer_email
      |> AppointmentCancellation.cancellation_email_organizer(appointment_details)
      |> deliver()

    Logger.info("Cancellation email sent to organizer",
      sent: match?({:ok, _}, result)
    )

    result
  end

  @doc """
  Sends cancellation emails to both organizer and attendee.
  """
  @spec send_cancellation_emails(map()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_cancellation_emails(appointment_details) do
    Logger.info("Sending appointment cancellations",
      title: appointment_details[:title]
    )

    organizer_result =
      send_cancellation_email_to_organizer(
        appointment_details.organizer_email,
        appointment_details
      )

    attendee_result =
      send_cancellation_email_to_attendee(
        appointment_details.attendee_email,
        appointment_details
      )

    Logger.info("Appointment cancellations sent",
      organizer_sent: match?({:ok, _}, organizer_result),
      attendee_sent: match?({:ok, _}, attendee_result)
    )

    {organizer_result, attendee_result}
  end

  @doc """
  Sends a calendar sync error notification to the calendar owner.
  This is only sent when calendar event creation fails after all retries.
  """
  @spec send_calendar_sync_error(map(), any()) :: {:ok, any()} | {:error, any()}
  def send_calendar_sync_error(meeting, error_reason) do
    # Use organizer's email from the meeting, fallback to FROM email if not available
    owner_email =
      meeting.organizer_email ||
        Application.get_env(:tymeslot, :email)[:from_email] ||
        System.get_env("POSTMARK_FROM_EMAIL")

    Logger.info("Sending calendar sync error notification",
      meeting_id: meeting.id,
      organizer_email: owner_email
    )

    html_body = CalendarSyncError.render(meeting, error_reason)

    email =
      MjmlEmail.base_email()
      |> Email.to({meeting.organizer_name || "Calendar Owner", owner_email})
      |> Email.subject("⚠️ Calendar Sync Error - Manual Action Required")
      |> Email.html_body(html_body)

    deliver(email)
  end

  @doc """
  Sends an email verification email to a new user.
  """
  @spec send_email_verification(map(), String.t()) :: {:ok, any()} | {:error, any()}
  def send_email_verification(user, verification_url) do
    Logger.info("Sending email verification", user_id: user.id)

    html_body = EmailVerification.render(user, verification_url)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject("Verify your email address")
      |> Email.html_body(html_body)

    deliver(email)
  end

  @doc """
  Sends a password reset email to a user.
  """
  @spec send_password_reset(map(), String.t()) :: {:ok, any()} | {:error, any()}
  def send_password_reset(user, reset_url) do
    Logger.info("Sending password reset email", user_id: user.id)

    html_body = PasswordReset.render(user, reset_url)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject("Reset your password")
      |> Email.html_body(html_body)

    deliver(email)
  end

  @doc """
  Sends an email change verification email to the NEW email address.
  """
  @spec send_email_change_verification(map(), String.t(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_email_change_verification(user, new_email, verification_url) do
    Logger.info("Sending email change verification",
      user_id: user.id,
      new_email: new_email
    )

    html_body = EmailChangeVerification.render(user, new_email, verification_url)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || new_email, new_email})
      |> Email.subject("Verify your new email address")
      |> Email.html_body(html_body)

    deliver(email)
  end

  @doc """
  Sends an email change notification to the OLD email address.
  """
  @spec send_email_change_notification(map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_email_change_notification(user, new_email) do
    Logger.info("Sending email change notification",
      user_id: user.id,
      old_email: user.email,
      new_email: new_email
    )

    request_time = DateTime.utc_now()
    html_body = EmailChangeNotification.render(user, new_email, request_time)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject("⚠️ Email Change Request - Security Alert")
      |> Email.html_body(html_body)

    deliver(email)
  end

  @doc """
  Sends email change confirmation to both OLD and NEW email addresses.
  """
  @spec send_email_change_confirmations(map(), String.t(), String.t()) ::
          {{:ok, any()} | {:error, any()}, {:ok, any()} | {:error, any()}}
  def send_email_change_confirmations(user, old_email, new_email) do
    Logger.info("Sending email change confirmations",
      user_id: user.id,
      old_email: old_email,
      new_email: new_email
    )

    confirmed_time = DateTime.utc_now()

    # Send to old email
    html_body_old = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, true)

    email_old =
      MjmlEmail.base_email()
      |> Email.to({user.name || old_email, old_email})
      |> Email.subject("Email Address Changed - Tymeslot Account")
      |> Email.html_body(html_body_old)

    old_result = deliver(email_old)

    # Send to new email
    html_body_new = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, false)

    email_new =
      MjmlEmail.base_email()
      |> Email.to({user.name || new_email, new_email})
      |> Email.subject("Email Address Changed Successfully")
      |> Email.html_body(html_body_new)

    new_result = deliver(email_new)

    Logger.info("Email change confirmations sent",
      old_sent: match?({:ok, _}, old_result),
      new_sent: match?({:ok, _}, new_result)
    )

    {old_result, new_result}
  end

  @doc """
  Sends a contact form email.
  """
  @spec send_contact_form(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_contact_form(name, from_email, subject, message) do
    Logger.info("Sending contact form email",
      from: from_email,
      subject: subject
    )

    email = ContactForm.contact_form_email(name, from_email, subject, message)
    deliver(email)
  end

  @doc """
  Sends a reschedule request email.
  """
  @spec send_reschedule_request(map()) :: {:ok, any()} | {:error, any()}
  def send_reschedule_request(meeting) do
    Logger.info("Sending reschedule request",
      meeting_id: meeting.id,
      to: meeting.attendee_email
    )

    email = RescheduleRequest.reschedule_request_email(meeting)
    deliver(email)
  end

  @doc """
  Delivers an email using the configured mailer with circuit breaker and retry logic.
  """
  @spec deliver(Swoosh.Email.t()) :: {:ok, any()} | {:error, any()}
  def deliver(email) do
    Logger.debug("Delivering email via Mailer",
      to: email.to,
      subject: email.subject
    )

    # Use circuit breaker with retry logic for email delivery
    CircuitBreaker.call(:email_service_breaker, fn ->
      Retry.with_backoff(
        fn -> do_deliver(email) end,
        max_attempts: 3,
        initial_delay: 1000,
        max_delay: 10_000,
        retriable?: &email_retriable?/1
      )
    end)
  end

  defp do_deliver(email) do
    case Mailer.deliver(email) do
      {:ok, _email} = result ->
        Logger.info("Email delivered successfully",
          to: email.to,
          subject: email.subject
        )

        result

      {:error, reason} = error ->
        Logger.error("Failed to deliver email",
          to: email.to,
          subject: email.subject,
          reason: inspect(reason)
        )

        error
    end
  end

  # Determine if an email error is retriable
  defp email_retriable?(reason) when is_binary(reason) do
    retriable_patterns = [
      "timeout",
      "connection refused",
      "network",
      "temporarily unavailable",
      "rate limit",
      "500",
      "502",
      "503",
      "504"
    ]

    down = String.downcase(reason)
    Enum.any?(retriable_patterns, fn pattern -> String.contains?(down, pattern) end)
  end

  defp email_retriable?(%{status_code: code}) when code in [500, 502, 503, 504] do
    true
  end

  defp email_retriable?(:timeout), do: true
  defp email_retriable?(:closed), do: true
  defp email_retriable?(:econnrefused), do: true
  defp email_retriable?(_), do: false
end
