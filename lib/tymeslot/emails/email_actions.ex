defmodule Tymeslot.Emails.EmailActions do
  @moduledoc """
  Every action an email job can carry: its name as stored in the job's
  `"action"` arg, the args it cannot run without, and the handler that runs
  it.

  One table, read by `Tymeslot.Workers.EmailWorker` when a job is built
  (`validate/2` refuses an unknown action, or one missing a required arg, at
  insert rather than at run time) and by
  `Tymeslot.Notifications.EmailHandlers` when it runs. A new email type is
  one entry here; a typo in a scheduler's action fails its insert instead of
  being discarded as "Unknown action" hours later.

  The names are persisted in queued jobs, so an entry is never renamed: a job
  inserted under the old name would find no handler. Required args are
  checked by key, not value, since some carry an explicit `nil`.

  A handler is `{module, function}`, called with the args, or
  `{module, function, :with_job_id}`, also called with the Oban job id, which
  the handler passes to `Tymeslot.Workers.DeliveryClaims` so a rescued job
  does not repeat a send it already made.
  """

  alias Ecto.Changeset
  alias Tymeslot.Notifications.Email.AdminEmails
  alias Tymeslot.Notifications.Email.AuthEmails
  alias Tymeslot.Notifications.Email.BookingApprovalEmails
  alias Tymeslot.Notifications.Email.EndChangeEmails
  alias Tymeslot.Notifications.Email.GroupMeetingEmails
  alias Tymeslot.Notifications.Email.GuestEmails
  alias Tymeslot.Notifications.Email.IntegrationEmails
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Email.PollEmails
  alias Tymeslot.Notifications.Email.RescheduleEmails
  alias Tymeslot.Notifications.Email.RescheduleRequestEmails
  alias Tymeslot.Notifications.Email.SeatEmails

  @type handler :: {module(), atom()} | {module(), atom(), :with_job_id}

  # The per-seat actions, named by atom at their call sites: `:seat_cancellation`
  # (a seat's own cancellation) and `:seat_meeting_cancellation` (a live
  # participant's copy of a whole meeting's cancellation) are deliberately
  # close strings for different actions, the near-collision a retyped copy
  # could miss.
  @seat_actions %{
    seat_confirmation: "send_seat_confirmation_emails",
    seat_cancellation: "send_seat_cancellation_emails",
    seat_meeting_cancellation: "send_seat_meeting_cancellation",
    seat_reschedule: "send_seat_reschedule_emails",
    seat_reschedule_request: "send_seat_reschedule_request",
    seat_reminder: "send_seat_reminder"
  }

  @actions %{
    # Meetings
    "send_confirmation_emails" => {["meeting_id"], {MeetingEmails, :handle_confirmation_emails}},
    "send_cancellation_emails" =>
      {["meeting_id"], {MeetingEmails, :handle_cancellation_emails, :with_job_id}},
    "send_reschedule_emails" =>
      {["meeting_id"], {RescheduleEmails, :handle_reschedule_emails, :with_job_id}},
    "send_end_change_emails" =>
      {["meeting_id", "start_time"], {EndChangeEmails, :handle_end_change_emails, :with_job_id}},
    "send_reminder_emails" =>
      {["meeting_id", "reminder_value", "reminder_unit"],
       {MeetingEmails, :handle_reminder_emails}},
    "send_reschedule_request" =>
      {["meeting_id"], {RescheduleRequestEmails, :handle_reschedule_request}},
    "send_guest_invitations" =>
      {["meeting_id", "guest_ids"], {GuestEmails, :handle_guest_invitations}},
    # Seats
    "send_seat_confirmation_emails" =>
      {["meeting_id", "participant_id"], {SeatEmails, :handle_seat_confirmation_emails}},
    "send_seat_cancellation_emails" =>
      {["meeting_id", "participant_id", "slot_freed"],
       {SeatEmails, :handle_seat_cancellation_emails, :with_job_id}},
    "send_seat_meeting_cancellation" =>
      {["meeting_id", "participant_id"],
       {GroupMeetingEmails, :handle_seat_meeting_cancellation_emails}},
    "send_seat_reschedule_emails" =>
      {["meeting_id", "participant_id", "old_participant_id"],
       {SeatEmails, :handle_seat_reschedule_emails, :with_job_id}},
    "send_seat_reschedule_request" =>
      {["meeting_id", "participant_id"], {GroupMeetingEmails, :handle_seat_reschedule_request}},
    "send_seat_reminder" =>
      {["meeting_id", "participant_id", "reminder_value", "reminder_unit"],
       {GroupMeetingEmails, :handle_seat_reminder_emails}},
    # Booking requests
    "send_booking_request_emails" =>
      {["meeting_id"], {BookingApprovalEmails, :handle_booking_request_emails, :with_job_id}},
    "send_booking_approval_nudge" =>
      {["meeting_id"], {BookingApprovalEmails, :handle_booking_approval_nudge}},
    "send_booking_request_outcome" =>
      {["meeting_id", "variant"], {BookingApprovalEmails, :handle_booking_request_outcome}},
    "send_reschedule_request_expired" =>
      {["meeting_id"], {BookingApprovalEmails, :handle_reschedule_request_expired}},
    # Polls
    "send_poll_deadline_reminders" =>
      {["poll_id"], {PollEmails, :handle_deadline_reminders, :with_job_id}},
    "send_poll_host_nudge" =>
      {["poll_id", "variant"], {PollEmails, :handle_host_nudge, :with_job_id}},
    # Accounts
    "send_email_verification" =>
      {["user_id", "verification_url_encrypted"], {AuthEmails, :handle_email_verification}},
    "send_password_reset" =>
      {["user_id", "reset_url_encrypted"], {AuthEmails, :handle_password_reset}},
    "send_no_password_to_reset" => {["user_id"], {AuthEmails, :handle_no_password_to_reset}},
    "send_signup_attempt_notice" => {["user_id"], {AuthEmails, :handle_signup_attempt_notice}},
    "send_social_signup_confirmation" =>
      {["email", "provider", "confirm_url_encrypted"],
       {AuthEmails, :handle_social_signup_confirmation}},
    "send_account_deletion_notice" =>
      {["email", "scheduled_at", "restorable"], {AuthEmails, :handle_account_deletion_notice}},
    "send_email_change_verification" =>
      {["user_id", "new_email", "verification_url_encrypted", "token_hash"],
       {AuthEmails, :handle_email_change_verification}},
    "send_email_change_notification" =>
      {["user_id", "new_email"], {AuthEmails, :handle_email_change_notification}},
    "send_email_change_confirmations" =>
      {["user_id", "old_email", "new_email"], {AuthEmails, :handle_email_change_confirmations}},
    # Integrations
    "send_integration_unhealthy_notification" =>
      {["user_id", "integration_id", "integration_type"],
       {IntegrationEmails, :handle_integration_unhealthy_notification}},
    "send_integration_reauth_notification" =>
      {["user_id", "integration_id", "integration_type"],
       {IntegrationEmails, :handle_integration_reauth_notification}},
    "send_integration_paused_notification" =>
      {["user_id", "integration_id", "integration_type"],
       {IntegrationEmails, :handle_integration_paused_notification}},
    "send_video_room_creation_error_notification" =>
      {["user_id", "integration_id", "error_code"],
       {IntegrationEmails, :handle_video_room_creation_error_notification}},
    "send_calendars_removed_notification" =>
      {["user_id", "integration_id", "calendar_names"],
       {IntegrationEmails, :handle_calendars_removed_notification}},
    "send_calendar_invitation" =>
      {[
         "user_id",
         "attendee_email",
         "event_title",
         "event_uid",
         "event_start_at",
         "event_end_at"
       ], {IntegrationEmails, :handle_calendar_invitation}},
    "send_event_update_notification" =>
      {[
         "user_id",
         "event_uid",
         "integration_id",
         "attendee_emails",
         "before_title",
         "before_location",
         "before_description",
         "before_start_at",
         "before_end_at"
       ], {IntegrationEmails, :handle_event_update_notification, :with_job_id}},
    # Operator alerts
    "send_admin_alert" =>
      {["recipient", "category", "severity", "message", "metadata", "alert_hash"],
       {AdminEmails, :handle_admin_alert}},
    "send_admin_alert_digest" =>
      {["recipient", "entries"], {AdminEmails, :handle_admin_alert_digest}}
  }

  @doc "Every action name, as stored in a job's args."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@actions)

  @doc "The stored name of a per-seat action."
  @spec seat_action(atom()) :: String.t()
  def seat_action(seat_action), do: Map.fetch!(@seat_actions, seat_action)

  @doc "The args a job for `action` cannot run without."
  @spec required_fields(String.t()) :: {:ok, [String.t()]} | :error
  def required_fields(action) do
    with {:ok, {fields, _handler}} <- Map.fetch(@actions, action), do: {:ok, fields}
  end

  @doc "The handler that runs `action`."
  @spec handler(String.t()) :: {:ok, handler()} | :error
  def handler(action) do
    with {:ok, {_fields, handler}} <- Map.fetch(@actions, action), do: {:ok, handler}
  end

  @doc """
  Refuses, on the job changeset, args naming no known action or missing one
  of its required args.
  """
  @spec validate(Changeset.t(), term()) :: Changeset.t()
  def validate(changeset, %{"action" => action} = args) do
    case required_fields(action) do
      {:ok, fields} ->
        case Enum.reject(fields, &Map.has_key?(args, &1)) do
          [] ->
            changeset

          missing ->
            Changeset.add_error(
              changeset,
              :args,
              "missing required fields: #{Enum.join(missing, ", ")}"
            )
        end

      :error ->
        Changeset.add_error(changeset, :args, "unknown email action: #{inspect(action)}")
    end
  end

  def validate(changeset, _args), do: Changeset.add_error(changeset, :args, "missing an action")
end
