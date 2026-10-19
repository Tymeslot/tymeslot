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

  alias Tymeslot.Workers.SendConfiguredEmail

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
          optional(:organizer_locale) => String.t(),
          optional(:organizer_note) => String.t() | nil,
          optional(:start_time_attendee_tz) => DateTime.t(),
          optional(:start_time_owner_tz) => DateTime.t(),
          optional(:attendee_timezone) => String.t(),
          optional(:attendee_video_url) => String.t() | nil,
          optional(:guest_video_url) => String.t() | nil,
          optional(:reschedule_url) => String.t() | nil,
          optional(:cancel_url) => String.t() | nil,
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

  @doc """
  Enqueues an email built by a deployment-configured template module, for
  delivery by a background job that retries, and snoozes through an open
  email circuit, like every other transactional email.

  `template_key` names the configured module (`config :tymeslot,
  <template_key>, Module`) and `template_fun` the function that builds the
  email; it is called with the recipient (the user, for `{:user, id}`, or
  the address) followed by `template_args`, which must be plain JSON. Does
  nothing for a template the deployment has not configured; a pair that is
  not allowed, or arguments that are not plain JSON, return an error. See
  `Tymeslot.Workers.SendConfiguredEmail`.
  """
  @spec enqueue_configured(atom(), atom(), SendConfiguredEmail.recipient(), list()) ::
          :ok | {:error, term()}
  defdelegate enqueue_configured(template_key, template_fun, recipient, template_args),
    to: SendConfiguredEmail,
    as: :enqueue

  # Appointment emails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_confirmation_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_confirmation_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @doc "Tells an invitee their booking request was received but is not yet confirmed."
  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_booking_request_received(meeting), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_booking_request_received(meeting, opts), to: AppointmentEmails

  @doc "Asks the host to approve or decline a booking request, or reminds them."
  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_booking_approval_request(variant, meeting, urls, locale), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_booking_approval_request(variant, meeting, urls, locale, opts),
    to: AppointmentEmails

  @doc "Tells an invitee a booking request was declined or expired."
  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_booking_request_outcome(variant, meeting), to: AppointmentEmails

  @doc "Tells the host a booking was cancelled because a reschedule request lapsed."
  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_reschedule_request_expired(meeting, locale), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_guest_confirmation(guest_email, appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_seat_reschedule_to_participant(
                participant_email,
                appointment_details,
                old_event
              ),
              to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_seat_update_to_organizer(variant, organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_guest_reschedule(guest_email, appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_guest_cancellation(guest_email, appointment_details), to: AppointmentEmails

  @doc "Sends the reminder for an upcoming meeting to one of its guests."
  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_guest_reminder(guest_email, appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_confirmations(appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_reschedule_email_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_reschedule_email_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_end_change_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_guest_end_change(guest_email, appointment_details), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_end_change_to_organizer(meeting, organizer_email, notice), to: CalendarEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_reminder_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_reminder_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_appointment_reminders(appointment_details, time_until), to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_cancellation_email_to_attendee(attendee_email, appointment_details),
    to: AppointmentEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_cancellation_email_to_organizer(organizer_email, appointment_details),
    to: AppointmentEmails

  # Auth emails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_email_verification(user, verification_url), to: AuthEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_password_reset(user, reset_url), to: AuthEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_no_password_to_reset(user, sign_in_url), to: AuthEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_signup_attempt_notice(user, sign_in_url, reset_url), to: AuthEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_account_deletion_notice(recipient, scheduled_at, sign_in_url),
    to: AuthEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_social_signup_confirmation(recipient, provider, confirm_url), to: AuthEmails

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
  defdelegate send_integration_reauth_notification(user, integration, type),
    to: IntegrationEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_integration_paused_notification(user, integration, type, cutoff_days),
    to: IntegrationEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_video_room_creation_error_notification(user, integration),
    to: IntegrationEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_calendars_removed_notification(user, integration, calendar_names),
    to: IntegrationEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_admin_alert(recipient, category, severity, message, metadata),
    to: IntegrationEmails

  @impl Tymeslot.Emails.EmailServiceBehaviour
  defdelegate send_admin_alert_digest(recipient, digest), to: IntegrationEmails
end
