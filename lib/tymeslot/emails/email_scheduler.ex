defmodule Tymeslot.Emails.EmailScheduler do
  @moduledoc """
  Public API facade for scheduling email delivery jobs via Oban.

  This module is the single point of entry for enqueueing email jobs. Each
  function delegates to a focused category sub-module:

  - `MeetingScheduler` — confirmation, cancellation, reminder, reschedule, and
    booking-approval emails
  - `SeatScheduler`: a group booking's per-seat emails, one job per
    participant
  - `EndChangeScheduler`: the notices of a booking whose end the host moved
    in their own calendar
  - `AuthScheduler` — email verification, password reset, and the account
    notices sent instead of an on-screen answer (no password to reset, a
    sign-up attempt with a registered address)
  - `OnboardingScheduler`: the emails a new host asks for while setting up
    (their booking link)
  - `AccountScheduler` — email change verification and confirmations
  - `CalendarScheduler` — calendar invitations and event update notifications
  - `PollScheduler`: poll deadline reminders, host nudges and vote updates, and
    participants' voting links and receipts
  - `SessionScheduler`: a planned session's participant list, at its
    registration close
  - `SeatScheduler`: the emails of a single group-booking seat, one job per
    seat
  - `SeriesScheduler`: a booking series' one confirmation, the
    cancellation of several of its sessions at once, and the request and
    its outcome for a series held for approval
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
  alias Tymeslot.Emails.EmailScheduler.OnboardingScheduler
  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.Emails.EmailScheduler.SeatScheduler
  alias Tymeslot.Emails.EmailScheduler.SeriesScheduler
  alias Tymeslot.Emails.EmailScheduler.SessionScheduler

  # Meeting emails

  defdelegate schedule_confirmation_emails(meeting_id), to: MeetingScheduler
  defdelegate schedule_seat_confirmation_emails(meeting_id, participant_id), to: SeatScheduler
  defdelegate schedule_seat_slot_revived_email(meeting_id, participant_id), to: SeatScheduler
  defdelegate schedule_cancellation_emails(meeting_id, opts \\ []), to: MeetingScheduler
  defdelegate schedule_verification_email(meeting_id, send \\ 1), to: MeetingScheduler

  defdelegate schedule_seat_verification_email(meeting_id, participant_id, send \\ 1),
    to: SeatScheduler

  defdelegate schedule_reschedule_emails(meeting, original, opts \\ []), to: MeetingScheduler
  defdelegate schedule_end_change_emails(meeting), to: EndChangeScheduler

  # Booking series emails

  defdelegate schedule_series_confirmation_emails(series_id), to: SeriesScheduler
  defdelegate schedule_series_request_emails(series_id, relevant_until), to: SeriesScheduler

  defdelegate schedule_series_request_nudge(series_id, send_at, relevant_until),
    to: SeriesScheduler

  defdelegate schedule_series_request_outcome(series_id, variant, relevant_until),
    to: SeriesScheduler

  defdelegate schedule_series_cancellation_emails(series_id, occurrence_ids, cancelled_by),
    to: SeriesScheduler

  defdelegate schedule_seat_cancellation_emails(meeting_id, participant_id, slot),
    to: SeatScheduler

  defdelegate schedule_reminder_emails(meeting_id, reminder_value, reminder_unit),
    to: MeetingScheduler

  defdelegate schedule_reminder_emails(meeting_id, reminder_value, reminder_unit, scheduled_at),
    to: MeetingScheduler

  defdelegate schedule_seat_reschedule_emails(
                meeting_id,
                participant_id,
                old_participant_id,
                old_slot
              ),
              to: SeatScheduler

  defdelegate schedule_seat_meeting_cancellation_email(meeting_id, participant_id),
    to: SeatScheduler

  defdelegate schedule_seat_reminder_email(
                meeting_id,
                participant_id,
                reminder_value,
                reminder_unit,
                relevant_until
              ),
              to: SeatScheduler

  defdelegate schedule_seat_session_moved(meeting_id, participant_id, from),
    to: SeatScheduler

  defdelegate schedule_seat_reschedule_request(meeting_id, participant_id, requested_at),
    to: SeatScheduler

  defdelegate schedule_guest_invitations(meeting_id, guest_ids), to: MeetingScheduler

  defdelegate cancel_reminder_emails(meeting_id), to: MeetingScheduler

  defdelegate schedule_reschedule_request(meeting_id, requested_at), to: MeetingScheduler

  defdelegate schedule_reschedule_request_lapsed(meeting_id, relevant_until),
    to: MeetingScheduler

  defdelegate schedule_request_emails(meeting_id, opts), to: MeetingScheduler

  defdelegate schedule_approval_nudge(meeting_id, send_at, relevant_until),
    to: MeetingScheduler

  defdelegate schedule_request_outcome(meeting_id, variant, relevant_until),
    to: MeetingScheduler

  defdelegate schedule_reschedule_request_expired(meeting_id), to: MeetingScheduler
  defdelegate schedule_released_guest_cancellations(meeting_id), to: MeetingScheduler
  defdelegate cancel_approval_emails(meeting_id), to: MeetingScheduler

  # Auth emails

  defdelegate schedule_email_verification(user_id, verification_url, token_hash),
    to: AuthScheduler

  defdelegate schedule_password_reset(user_id, reset_url, token_hash), to: AuthScheduler

  defdelegate schedule_account_invitation(user_id, invitation_url, token_hash),
    to: AuthScheduler

  defdelegate schedule_no_password_to_reset(user_id), to: AuthScheduler
  defdelegate schedule_signup_attempt_notice(user_id), to: AuthScheduler
  defdelegate schedule_social_signup_confirmation(details), to: AuthScheduler
  defdelegate schedule_account_deletion_notice(details), to: AuthScheduler

  # Onboarding emails

  defdelegate schedule_booking_link(user_id), to: OnboardingScheduler

  # Account emails

  defdelegate schedule_email_change_emails(user_id, new_email, verification_url, token_hash),
    to: AccountScheduler

  defdelegate schedule_email_change_notification(user_id, new_email), to: AccountScheduler

  defdelegate schedule_email_change_confirmations(user_id, old_email, new_email),
    to: AccountScheduler

  # Calendar emails

  defdelegate schedule_calendar_invitation(params), to: CalendarScheduler
  defdelegate schedule_event_update_notification(params), to: CalendarScheduler
  defdelegate schedule_external_booking_change(meeting_id, discrepancy), to: CalendarScheduler
  defdelegate schedule_calendar_sync_error(meeting_id, error_reason), to: CalendarScheduler

  # Planned sessions

  defdelegate schedule_registration_closed(session), to: SessionScheduler
  defdelegate reschedule_registration_closed(previous, current), to: SessionScheduler
  defdelegate reschedule_registration_closed(previous, current, now), to: SessionScheduler

  # Poll emails

  defdelegate schedule_poll_reminders(poll), to: PollScheduler, as: :schedule_reminders

  defdelegate schedule_poll_deadline_nudge(poll),
    to: PollScheduler,
    as: :schedule_deadline_nudge

  defdelegate cancel_poll_reminders(poll_id), to: PollScheduler, as: :cancel_reminders
  defdelegate cancel_poll_deadline_jobs(poll_id), to: PollScheduler, as: :cancel_deadline_jobs

  defdelegate schedule_poll_all_voted_nudge(poll, round),
    to: PollScheduler,
    as: :schedule_all_voted_nudge

  defdelegate schedule_poll_participant_link(participant),
    to: PollScheduler,
    as: :schedule_participant_link

  defdelegate schedule_poll_vote_receipt(participant),
    to: PollScheduler,
    as: :schedule_vote_receipt

  defdelegate schedule_poll_vote_digest(poll), to: PollScheduler, as: :schedule_vote_digest

  defdelegate schedule_poll_invitation(participant),
    to: PollScheduler,
    as: :schedule_invitation

  defdelegate schedule_poll_invitation_again(participant),
    to: PollScheduler,
    as: :schedule_invitation_again

  defdelegate reschedule_poll_deadline_jobs(poll, invited?),
    to: PollScheduler,
    as: :reschedule_deadline_jobs

  defdelegate schedule_poll_new_times(poll, slots), to: PollScheduler, as: :schedule_new_times
  defdelegate schedule_poll_cancellation(poll), to: PollScheduler, as: :schedule_cancellation

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
