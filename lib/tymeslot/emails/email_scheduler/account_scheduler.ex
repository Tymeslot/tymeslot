defmodule Tymeslot.Emails.EmailScheduler.AccountScheduler do
  @moduledoc "Schedules account management emails via Oban."

  alias Tymeslot.Emails.EmailScheduler.{Helpers, LinkArg}
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @doc """
  Schedules email change verification and notification emails.

  Enqueues two jobs, in one transaction: one to send a verification email to
  the new address, and one to notify the current address of the pending
  change. Both use a 10-minute uniqueness window to prevent duplicate sends.
  A failure enqueues neither and is returned.

  The verification link is stored encrypted (see `LinkArg`). The job carries
  the token's hash instead, both as its uniqueness key (each request mints a
  new token, so each gets its own email) and so the worker can discard it once
  the token has been replaced or revoked.
  """
  @spec schedule_email_change_emails(term(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def schedule_email_change_emails(user_id, new_email, verification_url, token_hash) do
    verification =
      %{
        "action" => "send_email_change_verification",
        "user_id" => user_id,
        "new_email" => new_email,
        "token_hash" => token_hash
      }
      |> LinkArg.put("verification_url", verification_url)
      |> EmailWorker.new(
        unique: [
          period: 600,
          fields: [:args, :queue],
          keys: [:action, :user_id, :new_email, :token_hash]
        ]
      )

    # Both or neither: a verification link sent without the notice to the
    # current address would let a change slip past its owner.
    transaction =
      Repo.transaction(fn ->
        with {:ok, _scheduled} <- Helpers.insert(verification, user_id: user_id),
             {:ok, _scheduled} <- insert_email_change_notification(user_id, new_email) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, :ok} <- transaction, do: :ok
  end

  @doc """
  Schedules only the notice to the current address of a pending email change,
  for a change whose verification link is never sent. Same uniqueness window
  as `schedule_email_change_emails/4`.
  """
  @spec schedule_email_change_notification(term(), String.t()) :: :ok | {:error, term()}
  def schedule_email_change_notification(user_id, new_email) do
    user_id
    |> insert_email_change_notification(new_email)
    |> Helpers.ok()
  end

  defp insert_email_change_notification(user_id, new_email) do
    %{
      "action" => "send_email_change_notification",
      "user_id" => user_id,
      "new_email" => new_email
    }
    |> EmailWorker.new(
      unique: [
        period: 600,
        fields: [:args, :queue],
        keys: [:action, :user_id, :new_email]
      ]
    )
    |> Helpers.insert(user_id: user_id)
  end

  @doc """
  Schedules confirmation emails after a successful email change.

  Enqueues a job to send confirmations to both the old and new email
  addresses. Uses a 1-hour uniqueness window.
  """
  @spec schedule_email_change_confirmations(term(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def schedule_email_change_confirmations(user_id, old_email, new_email) do
    %{
      "action" => "send_email_change_confirmations",
      "user_id" => user_id,
      "old_email" => old_email,
      "new_email" => new_email
    }
    |> EmailWorker.new(
      unique: [
        period: 3600,
        fields: [:args, :queue],
        keys: [:action, :user_id, :old_email, :new_email]
      ]
    )
    |> Helpers.insert(user_id: user_id)
    |> Helpers.ok()
  end
end
