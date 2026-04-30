defmodule Tymeslot.Workers.EmailWorkerHandlers do
  @moduledoc """
  Internal handlers for EmailWorker actions.
  """

  require Logger

  alias Tymeslot.Workers.EmailWorkerHandlers.AdminEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.AuthEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.IntegrationEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  # Static dispatch table — keeps `execute_email_action/2` simple and lets
  # adding a new email type be a one-line change. Each entry maps the
  # serialised action name to the function that handles its args.
  @action_handlers %{
    "send_admin_alert" => {AdminEmails, :handle_admin_alert},
    "send_confirmation_emails" => {MeetingEmails, :handle_confirmation_emails},
    "send_cancellation_emails" => {MeetingEmails, :handle_cancellation_emails},
    "send_reminder_emails" => {MeetingEmails, :handle_reminder_emails},
    "send_reschedule_request" => {MeetingEmails, :handle_reschedule_request},
    "send_email_change_confirmations" => {AuthEmails, :handle_email_change_confirmations},
    "send_email_verification" => {AuthEmails, :handle_email_verification},
    "send_password_reset" => {AuthEmails, :handle_password_reset},
    "send_email_change_verification" => {AuthEmails, :handle_email_change_verification},
    "send_email_change_notification" => {AuthEmails, :handle_email_change_notification},
    "send_integration_unhealthy_notification" =>
      {IntegrationEmails, :handle_integration_unhealthy_notification},
    "send_integration_paused_notification" =>
      {IntegrationEmails, :handle_integration_paused_notification},
    "send_calendar_invitation" => {IntegrationEmails, :handle_calendar_invitation},
    "send_event_update_notification" => {IntegrationEmails, :handle_event_update_notification}
  }

  @doc """
  Executes the specified email action with the given arguments.

  This is the primary entry point for the EmailWorker to process various types of
  email jobs, including confirmations, reminders, and authentication emails.

  Returns `:ok` on success, `{:error, reason}` for retriable failures,
  `{:discard, reason}` for fatal errors that shouldn't be retried,
  or `{:snooze, seconds}` if the job should be delayed.
  """
  @spec execute_email_action(String.t(), %{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()} | {:snooze, integer()}
  def execute_email_action(action, args) do
    case Map.fetch(@action_handlers, action) do
      {:ok, {module, fun}} -> apply(module, fun, [args])
      :error -> {:discard, "Unknown action: #{action}"}
    end
  end
end
