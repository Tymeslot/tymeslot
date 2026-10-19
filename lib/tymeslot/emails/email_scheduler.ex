defmodule Tymeslot.Emails.EmailScheduler do
  @moduledoc """
  Public API facade for scheduling email delivery jobs via Oban.

  This module is the single point of entry for enqueueing email jobs. Each
  function delegates to a focused category sub-module:

  - `MeetingScheduler` — confirmation, cancellation, reminder, reschedule, and
    booking-approval emails
  - `EndChangeScheduler`: the notices of a booking whose end the host moved
    in their own calendar
  - `AuthScheduler` — email verification, password reset, and the account
    notices sent instead of an on-screen answer (no password to reset, a
    sign-up attempt with a registered address)
  - `AccountScheduler` — email change verification and confirmations
  - `CalendarScheduler` — calendar invitations and event update notifications
  - `PollScheduler`: poll deadline reminders and host nudges
  - `IntegrationScheduler` — integration health notifications and admin alerts

  Callers should reference this module directly — no delegation functions exist
  on `Tymeslot.Workers.EmailWorker`.
  """

  alias Tymeslot.Emails.EmailScheduler.AccountScheduler
  alias Tymeslot.Emails.EmailScheduler.AuthScheduler
  alias Tymeslot.Emails.EmailScheduler.CalendarScheduler
  alias Tymeslot.Emails.EmailScheduler.EndChangeScheduler
  alias Tymeslot.Emails.EmailScheduler.IntegrationScheduler
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler
  alias Tymeslot.Emails.EmailScheduler.PollScheduler

  # Meeting emails

  defdelegate schedule_confirmation_emails(meeting_id), to: MeetingScheduler
  defdelegate schedule_seat_confirmation_emails(meeting_id, participant_id), to: MeetingScheduler
  defdelegate schedule_cancellation_emails(meeting_id), to: MeetingScheduler
  defdelegate schedule_reschedule_emails(meeting, original), to: MeetingScheduler
  defdelegate schedule_end_change_emails(meeting), to: EndChangeScheduler

  defdelegate schedule_seat_cancellation_emails(meeting_id, participant_id, slot_freed?),
    to: MeetingScheduler

  defdelegate schedule_reminder_emails(meeting_id, reminder_value, reminder_unit),
    to: MeetingScheduler

  defdelegate schedule_reminder_emails(meeting_id, reminder_value, reminder_unit, scheduled_at),
    to: MeetingScheduler

  defdelegate schedule_seat_reschedule_emails(
                meeting_id,
                participant_id,
                old_participant_id,
                old_slot_freed?
              ),
              to: MeetingScheduler

  defdelegate schedule_seat_meeting_cancellation_email(meeting_id, participant_id),
    to: MeetingScheduler

  defdelegate schedule_seat_reminder_email(
                meeting_id,
                participant_id,
                reminder_value,
                reminder_unit
              ),
              to: MeetingScheduler

  defdelegate schedule_seat_reschedule_request(meeting_id, participant_id, requested_at),
    to: MeetingScheduler

  defdelegate schedule_guest_invitations(meeting_id, guest_ids), to: MeetingScheduler

  defdelegate cancel_reminder_emails(meeting_id), to: MeetingScheduler

  defdelegate schedule_reschedule_request(meeting_id, requested_at), to: MeetingScheduler

  defdelegate schedule_request_emails(meeting_id, opts \\ []), to: MeetingScheduler
  defdelegate schedule_approval_nudge(meeting_id, send_at), to: MeetingScheduler
  defdelegate schedule_request_outcome(meeting_id, variant), to: MeetingScheduler
  defdelegate schedule_reschedule_request_expired(meeting_id), to: MeetingScheduler
  defdelegate cancel_approval_emails(meeting_id), to: MeetingScheduler

  # Auth emails

  defdelegate schedule_email_verification(user_id, verification_url, token_hash),
    to: AuthScheduler

  defdelegate schedule_password_reset(user_id, reset_url, token_hash), to: AuthScheduler
  defdelegate schedule_no_password_to_reset(user_id), to: AuthScheduler
  defdelegate schedule_signup_attempt_notice(user_id), to: AuthScheduler
  defdelegate schedule_social_signup_confirmation(details), to: AuthScheduler
  defdelegate schedule_account_deletion_notice(details), to: AuthScheduler

  # Account emails

  defdelegate schedule_email_change_emails(user_id, new_email, verification_url, token_hash),
    to: AccountScheduler

  defdelegate schedule_email_change_notification(user_id, new_email), to: AccountScheduler

  defdelegate schedule_email_change_confirmations(user_id, old_email, new_email),
    to: AccountScheduler

  # Calendar emails

  defdelegate schedule_calendar_invitation(params), to: CalendarScheduler
  defdelegate schedule_event_update_notification(params), to: CalendarScheduler

  # Poll emails

  defdelegate schedule_poll_deadline_jobs(poll), to: PollScheduler, as: :schedule_deadline_jobs
  defdelegate cancel_poll_deadline_jobs(poll_id), to: PollScheduler, as: :cancel_deadline_jobs

  defdelegate schedule_poll_all_voted_nudge(poll),
    to: PollScheduler,
    as: :schedule_all_voted_nudge

  # Integration emails

  defdelegate schedule_integration_unhealthy_notification(user, integration, type),
    to: IntegrationScheduler

  defdelegate schedule_integration_reauth_notification(user, integration, type),
    to: IntegrationScheduler

  defdelegate schedule_integration_paused_notification(user, integration, type, cutoff_days),
    to: IntegrationScheduler

  defdelegate schedule_video_room_creation_error_notification(user_id, integration_id, code),
    to: IntegrationScheduler

  defdelegate schedule_calendars_removed_notification(user_id, integration_id, calendar_names),
    to: IntegrationScheduler

  defdelegate schedule_admin_alert(recipient, category, severity, message, metadata, opts \\ []),
    to: IntegrationScheduler

  defdelegate schedule_admin_alert_digest(recipient, digest), to: IntegrationScheduler
end
