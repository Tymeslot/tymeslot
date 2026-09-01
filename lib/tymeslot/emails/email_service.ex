defmodule Tymeslot.Emails.EmailService do
  @moduledoc """
  Main email service for sending various types of emails.

  This module is a facade that delegates to focused category sub-modules:

  - `AppointmentEmails` — confirmations, reminders, cancellations
  - `AuthEmails` — email verification, password reset
  - `AccountEmails` — email change verification, notification, confirmation
  - `CalendarEmails` — sync errors, external booking changes, invitations, reschedule requests
  - `IntegrationEmails` — integration health notifications, admin alerts

  Type definitions used by email templates are declared here and referenced as
  `Tymeslot.Emails.EmailService.appointment_details()` etc.
  """

  @behaviour Tymeslot.Emails.EmailServiceBehaviour

  alias Tymeslot.Emails.EmailService.{
    AccountEmails,
    AppointmentEmails,
    AuthEmails,
    CalendarEmails,
    IntegrationEmails
  }

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
          optional(:attendee_video_url) => String.t() | nil,
          optional(:reschedule_url) => String.t(),
          optional(:cancel_url) => String.t(),
          optional(:booking_url) => String.t(),
          optional(:meeting_url) => String.t(),
          optional(atom()) => term()
        }

  @type user_map :: %{
          required(:email) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:id) => term(),
          optional(atom()) => term()
        }

  # Appointment emails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_confirmation_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_confirmation_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_guest_confirmation(guest_email, appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_confirmations(appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_reschedule_email_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_reschedule_email_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_reschedule_emails(appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_reminder_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_reminder_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_reminders(appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_reminders(appointment_details, time_until), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_cancellation(email, appointment_details), to: AppointmentEmails

  defdelegate send_cancellation_email_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  defdelegate send_cancellation_email_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_cancellation_emails(appointment_details), to: AppointmentEmails

  # Auth emails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_email_verification(user, verification_url), to: AuthEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_password_reset(user, reset_url), to: AuthEmails

  # Account emails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_email_change_verification(user, new_email, verification_url),
    to: AccountEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_email_change_notification(user, new_email), to: AccountEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_email_change_confirmations(user, old_email, new_email), to: AccountEmails

  # Calendar emails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_calendar_sync_error(meeting, error_reason), to: CalendarEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_external_booking_change(meeting, organizer_email, discrepancy),
    to: CalendarEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_calendar_invitation(attendee_email, invitation_details), to: CalendarEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_event_update_notification(attendee_email, update_details), to: CalendarEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_reschedule_request(meeting), to: CalendarEmails

  # Integration emails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_integration_unhealthy_notification(user, integration, type),
    to: IntegrationEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_integration_paused_notification(user, integration, type, cutoff_days),
    to: IntegrationEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_admin_alert(recipient, category, severity, message, metadata),
    to: IntegrationEmails
end
