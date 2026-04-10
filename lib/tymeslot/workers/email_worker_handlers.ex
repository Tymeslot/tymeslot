defmodule Tymeslot.Workers.EmailWorkerHandlers do
  @moduledoc """
  Internal handlers for EmailWorker actions.
  """

  require Logger

  alias Tymeslot.Workers.EmailWorkerHandlers.AuthEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.IntegrationEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

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
    case action do
      "send_confirmation_emails" ->
        MeetingEmails.handle_confirmation_emails(args)

      "send_cancellation_emails" ->
        MeetingEmails.handle_cancellation_emails(args)

      "send_reminder_emails" ->
        MeetingEmails.handle_reminder_emails(args)

      "send_reschedule_request" ->
        MeetingEmails.handle_reschedule_request(args)

      "send_email_change_confirmations" ->
        AuthEmails.handle_email_change_confirmations(args)

      "send_email_verification" ->
        AuthEmails.handle_email_verification(args)

      "send_password_reset" ->
        AuthEmails.handle_password_reset(args)

      "send_email_change_verification" ->
        AuthEmails.handle_email_change_verification(args)

      "send_email_change_notification" ->
        AuthEmails.handle_email_change_notification(args)

      "send_integration_unhealthy_notification" ->
        IntegrationEmails.handle_integration_unhealthy_notification(args)

      "send_calendar_invitation" ->
        IntegrationEmails.handle_calendar_invitation(args)

      "send_event_update_notification" ->
        IntegrationEmails.handle_event_update_notification(args)

      "send_admin_alert" ->
        handle_admin_alert(args)

      _other ->
        {:discard, "Unknown action: #{action}"}
    end
  end

  defp handle_admin_alert(%{
         "recipient" => recipient,
         "category" => category,
         "severity" => severity_str,
         "message" => message,
         "metadata" => metadata
       }) do
    severity = severity_atom(severity_str)

    case email_service_module().send_admin_alert(recipient, category, severity, message, metadata) do
      {:ok, _result} ->
        Logger.info("Admin alert email delivered",
          category: category,
          recipient: recipient
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to deliver admin alert email",
          category: category,
          error: inspect(reason)
        )

        {:error, "Failed to deliver admin alert"}
    end
  end

  defp severity_atom("info"), do: :info
  defp severity_atom("warning"), do: :warning
  defp severity_atom("error"), do: :error
  defp severity_atom(_other), do: :warning

  defp email_service_module do
    Application.get_env(:tymeslot, :email_service_module) ||
      Application.get_env(:tymeslot, :email_service) ||
      Tymeslot.Emails.EmailService
  end
end
