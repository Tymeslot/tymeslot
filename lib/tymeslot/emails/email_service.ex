defmodule Tymeslot.Emails.EmailService do
  @moduledoc """
  Main email service for sending various types of emails.
  """

  @behaviour Tymeslot.Emails.EmailServiceBehaviour

  require Logger

  @type appointment_details :: %{
          required(:attendee_name) => String.t(),
          required(:attendee_email) => String.t(),
          required(:organizer_name) => String.t(),
          required(:organizer_email) => String.t(),
          required(:date) => Date.t(),
          required(:start_time) => DateTime.t(),
          required(:duration) => integer(),
          required(:location) => String.t(),
          required(:location_type) => atom(),
          required(:meeting_type) => String.t(),
          optional(:attendee_locale) => String.t(),
          optional(:start_time_attendee_tz) => DateTime.t(),
          optional(:start_time_owner_tz) => DateTime.t(),
          optional(:reschedule_url) => String.t(),
          optional(:cancel_url) => String.t(),
          optional(:meeting_url) => String.t(),
          optional(atom()) => term()
        }

  @type user_map :: %{
          required(:email) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:id) => term(),
          optional(atom()) => term()
        }

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.AdminAlerts

  alias Tymeslot.Emails.Templates.{
    AdminAlert,
    AppointmentCancellation,
    AppointmentConfirmationAttendee,
    AppointmentConfirmationOrganizer,
    AppointmentReminderAttendee,
    AppointmentReminderOrganizer,
    CalendarInvitation,
    CalendarSyncError,
    EmailChangeConfirmed,
    EmailChangeNotification,
    EmailChangeVerification,
    EmailVerification,
    EventUpdateNotification,
    ExternalBookingChange,
    IntegrationUnhealthy,
    PasswordReset,
    RescheduleRequest
  }

  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Profiles

  alias Swoosh.Email

  @doc """
  Sends an appointment confirmation email to the organizer.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_confirmation_to_organizer(String.t(), appointment_details()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_confirmation_to_organizer(organizer_email, appointment_details) do
    organizer_email
    |> AppointmentConfirmationOrganizer.confirmation_email(appointment_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends an appointment confirmation email to the attendee.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_confirmation_to_attendee(String.t(), appointment_details()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_confirmation_to_attendee(attendee_email, appointment_details) do
    attendee_email
    |> AppointmentConfirmationAttendee.confirmation_email(appointment_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends appointment confirmations to both organizer and attendee.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_confirmations(appointment_details()) ::
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
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_reminder_to_organizer(String.t(), appointment_details()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_reminder_to_organizer(organizer_email, appointment_details) do
    organizer_email
    |> AppointmentReminderOrganizer.reminder_email(appointment_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends an appointment reminder email to the attendee.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_reminder_to_attendee(String.t(), appointment_details()) ::
          {:ok, any()} | {:error, any()}
  def send_appointment_reminder_to_attendee(attendee_email, appointment_details) do
    attendee_email
    |> AppointmentReminderAttendee.reminder_email(appointment_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends appointment reminders to both organizer and attendee.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_reminders(appointment_details()) ::
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
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_reminders(appointment_details(), String.t()) ::
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
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_appointment_cancellation(String.t(), appointment_details()) ::
          {:ok, any()} | {:error, any()}
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
  @spec send_cancellation_email_to_attendee(String.t(), appointment_details()) ::
          {:ok, any()} | {:error, any()}
  def send_cancellation_email_to_attendee(attendee_email, appointment_details) do
    Logger.info("Sending appointment cancellation to attendee",
      title: appointment_details[:title]
    )

    result =
      attendee_email
      |> AppointmentCancellation.cancellation_email_attendee(appointment_details)
      |> Delivery.deliver()

    Logger.info("Cancellation email sent to attendee",
      sent: match?({:ok, _}, result)
    )

    result
  end

  @doc """
  Sends a cancellation email to the organizer.
  """
  @spec send_cancellation_email_to_organizer(String.t(), appointment_details()) ::
          {:ok, any()} | {:error, any()}
  def send_cancellation_email_to_organizer(organizer_email, appointment_details) do
    Logger.info("Sending appointment cancellation to organizer",
      title: appointment_details[:title]
    )

    result =
      organizer_email
      |> AppointmentCancellation.cancellation_email_organizer(appointment_details)
      |> Delivery.deliver()

    Logger.info("Cancellation email sent to organizer",
      sent: match?({:ok, _}, result)
    )

    result
  end

  @doc """
  Sends cancellation emails to both organizer and attendee.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_cancellation_emails(appointment_details()) ::
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
  @impl Tymeslot.Emails.EmailServiceBehaviour
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

    # Alert admin about calendar sync error
    AdminAlerts.report(:calendar_sync_error,
      summary: "Calendar sync failed for meeting",
      reason: error_reason,
      context: %{
        meeting_id: meeting.id,
        owner_email: owner_email,
        calendar_integration_id: Map.get(meeting, :calendar_integration_id)
      }
    )

    {html_body, text_body} = CalendarSyncError.render_both(meeting, error_reason)

    email =
      MjmlEmail.base_email()
      |> Email.to({meeting.organizer_name || "Calendar Owner", owner_email})
      |> Email.subject("⚠️ Calendar Sync Error - Manual Action Required")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Notifies an organizer that one of their meetings was changed in their external calendar.

  `discrepancy` is either `:deleted` (the event was removed from the external calendar)
  or `:modified` (the event was rescheduled in the external calendar).
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_external_booking_change(map(), String.t(), ExternalBookingChange.discrepancy()) ::
          {:ok, any()} | {:error, any()}
  def send_external_booking_change(meeting, organizer_email, discrepancy) do
    Logger.info("Sending external booking change notification",
      meeting_id: meeting.id,
      organizer_email: organizer_email,
      discrepancy: discrepancy
    )

    owner_timezone = resolve_owner_timezone(meeting)

    result =
      Delivery.deliver(
        ExternalBookingChange.build_email(meeting, organizer_email, discrepancy, owner_timezone)
      )

    Logger.info("External booking change notification sent",
      sent: match?({:ok, _}, result),
      discrepancy: discrepancy
    )

    result
  end

  @doc """
  Sends an email verification email to a new user.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_email_verification(user_map(), String.t()) :: {:ok, any()} | {:error, any()}
  def send_email_verification(user, verification_url) do
    Logger.info("Sending email verification", user_id: user.id)

    html_body = EmailVerification.render(user, verification_url)
    text_body = EmailVerification.render_text(user, verification_url)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject("Verify your email address")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Sends a password reset email to a user.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_password_reset(user_map(), String.t()) :: {:ok, any()} | {:error, any()}
  def send_password_reset(user, reset_url) do
    Logger.info("Sending password reset email", user_id: user.id)

    html_body = PasswordReset.render(user, reset_url)
    text_body = PasswordReset.render_text(user, reset_url)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject("Reset your password")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Sends an email change verification email to the NEW email address.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_email_change_verification(user_map(), String.t(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_email_change_verification(user, new_email, verification_url) do
    Logger.info("Sending email change verification",
      user_id: user.id,
      new_email: new_email
    )

    html_body = EmailChangeVerification.render(user, new_email, verification_url)
    text_body = EmailChangeVerification.render_text(user, new_email, verification_url)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || new_email, new_email})
      |> Email.subject("Verify your new email address")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Sends an email change notification to the OLD email address.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_email_change_notification(user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_email_change_notification(user, new_email) do
    Logger.info("Sending email change notification",
      user_id: user.id,
      old_email: user.email,
      new_email: new_email
    )

    request_time = DateTime.utc_now()
    html_body = EmailChangeNotification.render(user, new_email, request_time)
    text_body = EmailChangeNotification.render_text(user, new_email, request_time)

    email =
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject("⚠️ Email Change Request - Security Alert")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Sends email change confirmation to both OLD and NEW email addresses.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_email_change_confirmations(user_map(), String.t(), String.t()) ::
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

    text_body_old =
      EmailChangeConfirmed.render_text(user, old_email, new_email, confirmed_time, true)

    email_old =
      MjmlEmail.base_email()
      |> Email.to({user.name || old_email, old_email})
      |> Email.subject("Email Address Changed - Tymeslot Account")
      |> Email.html_body(html_body_old)
      |> Email.text_body(text_body_old)

    old_result = Delivery.deliver(email_old)

    # Send to new email
    html_body_new = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, false)

    text_body_new =
      EmailChangeConfirmed.render_text(user, old_email, new_email, confirmed_time, false)

    email_new =
      MjmlEmail.base_email()
      |> Email.to({user.name || new_email, new_email})
      |> Email.subject("Email Address Changed Successfully")
      |> Email.html_body(html_body_new)
      |> Email.text_body(text_body_new)

    new_result = Delivery.deliver(email_new)

    Logger.info("Email change confirmations sent",
      old_sent: match?({:ok, _}, old_result),
      new_sent: match?({:ok, _}, new_result)
    )

    {old_result, new_result}
  end

  @doc """
  Sends an integration unhealthy notification to the integration owner.
  Called when an integration has been failing health checks for over 48 hours.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_integration_unhealthy_notification(
          user_map(),
          %{required(:provider) => atom(), optional(atom()) => term()},
          atom() | String.t()
        ) ::
          {:ok, any()} | {:error, any()}
  def send_integration_unhealthy_notification(user, integration, type) do
    Logger.info("Sending integration unhealthy notification",
      user_id: user.id,
      integration_id: integration.id,
      type: type
    )

    html_body = IntegrationUnhealthy.render(user, integration, type)
    text_body = IntegrationUnhealthy.render_text(user, integration, type)
    type_label = if type == :video, do: "video", else: "calendar"

    display_name = Map.get(user, :name) || user.email

    email =
      MjmlEmail.base_email()
      |> Email.to({display_name, user.email})
      |> Email.subject("Your #{type_label} integration may need attention")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Sends a reschedule request email.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_reschedule_request(map()) :: {:ok, any()} | {:error, any()}
  def send_reschedule_request(meeting) do
    Logger.info("Sending reschedule request",
      meeting_id: meeting.id,
      to: meeting.attendee_email
    )

    email = RescheduleRequest.reschedule_request_email(meeting)
    Delivery.deliver(email)
  end

  @doc """
  Sends a calendar invitation email to an attendee for a dashboard-created event.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_calendar_invitation(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_calendar_invitation(attendee_email, invitation_details) do
    Logger.info("Sending calendar invitation",
      title: invitation_details[:event_title],
      to: attendee_email
    )

    attendee_email
    |> CalendarInvitation.invitation_email(invitation_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends an event update notification to an attendee with a change summary and updated .ics.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_event_update_notification(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_event_update_notification(attendee_email, update_details) do
    Logger.info("Sending event update notification",
      title: update_details[:event_title],
      to: attendee_email
    )

    attendee_email
    |> EventUpdateNotification.update_notification_email(update_details)
    |> Delivery.deliver()
  end

  @doc """
  Delivers an administrative alert email to the configured admin recipient.

  Used by `Tymeslot.Infrastructure.AdminAlerts.EmailNotifier` to send alerts
  generated by `Tymeslot.Infrastructure.AdminAlerts.send_alert/2`.
  """
  @impl Tymeslot.Emails.EmailServiceBehaviour
  @spec send_admin_alert(String.t(), String.t(), :info | :warning | :error, String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_admin_alert(recipient, category, severity, message, metadata) do
    Logger.info("Sending admin alert email",
      category: category,
      severity: severity,
      recipient: recipient
    )

    html_body = AdminAlert.render(category, severity, message, metadata)
    text_body = AdminAlert.render_text(category, severity, message, metadata)

    email =
      MjmlEmail.base_email()
      |> Email.to({"Tymeslot Operator", recipient})
      |> Email.subject("⚠️ Tymeslot Admin Alert: #{category}")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  defp resolve_owner_timezone(%{organizer_user_id: nil}), do: Profiles.get_default_timezone()
  defp resolve_owner_timezone(%{organizer_user_id: id}), do: Profiles.get_user_timezone(id)
  defp resolve_owner_timezone(_meeting), do: Profiles.get_default_timezone()
end
