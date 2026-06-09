defmodule Tymeslot.Emails.EmailScheduler do
  @moduledoc """
  Public API facade for scheduling email delivery jobs via Oban.

  This module is the single point of entry for enqueueing email jobs. Each
  function delegates to a focused category sub-module:

  - `MeetingScheduler` — confirmation, cancellation, reminder, and reschedule emails
  - `AuthScheduler` — email verification and password reset
  - `AccountScheduler` — email change verification and confirmations
  - `CalendarScheduler` — calendar invitations and event update notifications
  - `IntegrationScheduler` — integration health notifications and admin alerts

  Callers should reference this module directly — no delegation functions exist
  on `Tymeslot.Workers.EmailWorker`.
  """

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.AccountScheduler
  alias Tymeslot.Emails.EmailScheduler.AuthScheduler
  alias Tymeslot.Emails.EmailScheduler.CalendarScheduler
  alias Tymeslot.Emails.EmailScheduler.IntegrationScheduler
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler

  # Meeting emails

  defdelegate schedule_confirmation_emails(meeting_id), to: MeetingScheduler
  defdelegate schedule_cancellation_emails(meeting_id), to: MeetingScheduler

  defdelegate schedule_reminder_emails(meeting_id, reminder_value, reminder_unit),
    to: MeetingScheduler

  defdelegate schedule_reminder_emails(meeting_id, reminder_value, reminder_unit, scheduled_at),
    to: MeetingScheduler

  defdelegate schedule_reschedule_request(meeting_id), to: MeetingScheduler

  # Auth emails

  defdelegate schedule_email_verification(user_id, verification_url), to: AuthScheduler
  defdelegate schedule_password_reset(user_id, reset_url), to: AuthScheduler

  # Account emails

  defdelegate schedule_email_change_emails(user_id, new_email, verification_url),
    to: AccountScheduler

  defdelegate schedule_email_change_confirmations(user_id, old_email, new_email),
    to: AccountScheduler

  # Calendar emails

  defdelegate schedule_calendar_invitation(params), to: CalendarScheduler
  defdelegate schedule_event_update_notification(params), to: CalendarScheduler

  # Integration emails

  defdelegate schedule_integration_unhealthy_notification(user, integration, type),
    to: IntegrationScheduler

  defdelegate schedule_integration_paused_notification(user, integration, type, cutoff_days),
    to: IntegrationScheduler

  defdelegate schedule_admin_alert(recipient, category, severity, message, metadata, opts \\ []),
    to: IntegrationScheduler

  # --- Changeset validation (used by EmailWorker's Oban callback) ---

  @fields_by_action %{
    "send_confirmation_emails" => ["meeting_id"],
    "send_cancellation_emails" => ["meeting_id"],
    "send_reminder_emails" => ["meeting_id", "reminder_value", "reminder_unit"],
    "send_reschedule_request" => ["meeting_id"],
    "send_email_verification" => ["user_id", "verification_url"],
    "send_password_reset" => ["user_id", "reset_url"],
    "send_email_change_verification" => ["user_id", "new_email", "verification_url"],
    "send_email_change_notification" => ["user_id", "new_email"],
    "send_email_change_confirmations" => ["user_id", "old_email", "new_email"],
    "send_integration_unhealthy_notification" => [
      "user_id",
      "integration_id",
      "integration_type"
    ],
    "send_integration_paused_notification" => [
      "user_id",
      "integration_id",
      "integration_type"
    ],
    "send_calendar_invitation" => [
      "user_id",
      "attendee_email",
      "event_title",
      "event_uid",
      "event_start_at",
      "event_end_at"
    ],
    "send_event_update_notification" => [
      "user_id",
      "event_uid",
      "integration_id",
      "attendee_emails",
      "before_title",
      "before_location",
      "before_description",
      "before_start_at",
      "before_end_at"
    ],
    "send_admin_alert" => [
      "recipient",
      "category",
      "severity",
      "message",
      "metadata",
      "alert_hash"
    ]
  }

  @doc """
  Validates required fields for an Oban job changeset based on the action.

  Called by `Tymeslot.Workers.EmailWorker.changeset/2` to keep validation
  logic co-located with the scheduling functions that define the argument
  shapes.
  """
  @spec validate_args(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def validate_args(changeset, args) when is_map(args) do
    required = required_fields_for_action(Map.get(args, "action"))
    missing = Enum.reject(required, &Map.has_key?(args, &1))

    if missing == [] do
      changeset
    else
      Changeset.add_error(
        changeset,
        :args,
        "missing required fields: #{Enum.join(missing, ", ")}"
      )
    end
  end

  @spec validate_args(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def validate_args(changeset, _args) do
    Changeset.add_error(changeset, :args, "args must be a map")
  end

  defp required_fields_for_action(nil), do: ["action"]
  defp required_fields_for_action(action), do: Map.get(@fields_by_action, action, [])
end
