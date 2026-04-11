defmodule Tymeslot.Emails.EmailScheduler.AccountScheduler do
  @moduledoc "Schedules account management emails via Oban."

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @doc """
  Schedules email change verification and notification emails.

  Enqueues two jobs: one to send a verification email to the new address,
  and one to notify the current address of the pending change. Both use a
  10-minute uniqueness window to prevent duplicate sends.
  """
  @spec schedule_email_change_emails(term(), String.t(), String.t()) :: :ok
  def schedule_email_change_emails(user_id, new_email, verification_url) do
    with {:ok, _job1} <-
           Oban.insert(
             EmailWorker.new(
               %{
                 "action" => "send_email_change_verification",
                 "user_id" => user_id,
                 "new_email" => new_email,
                 "verification_url" => verification_url
               },
               unique: [
                 period: 600,
                 fields: [:args, :queue],
                 keys: [:action, :user_id, :new_email, :verification_url]
               ]
             )
           ),
         {:ok, _job2} <-
           Oban.insert(
             EmailWorker.new(
               %{
                 "action" => "send_email_change_notification",
                 "user_id" => user_id,
                 "new_email" => new_email
               },
               unique: [
                 period: 600,
                 fields: [:args, :queue],
                 keys: [:action, :user_id, :new_email]
               ]
             )
           ) do
      :ok
    else
      error ->
        Logger.error("Failed to enqueue email change emails",
          error: Helpers.format_insert_error(error),
          user_id: user_id
        )

        :ok
    end
  end

  @doc """
  Schedules confirmation emails after a successful email change.

  Enqueues a job to send confirmations to both the old and new email
  addresses. Uses a 1-hour uniqueness window.
  """
  @spec schedule_email_change_confirmations(term(), String.t(), String.t()) :: :ok
  def schedule_email_change_confirmations(user_id, old_email, new_email) do
    case Oban.insert(
           EmailWorker.new(
             %{
               "action" => "send_email_change_confirmations",
               "user_id" => user_id,
               "old_email" => old_email,
               "new_email" => new_email
             },
             unique: [
               period: 3600,
               fields: [:args, :queue],
               keys: [:action, :user_id, :old_email, :new_email]
             ]
           )
         ) do
      {:ok, _job} ->
        :ok

      error ->
        Logger.error("Failed to enqueue email change confirmations",
          error: Helpers.format_insert_error(error),
          user_id: user_id
        )

        :ok
    end
  end
end
