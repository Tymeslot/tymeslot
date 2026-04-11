defmodule Tymeslot.Emails.EmailScheduler.AuthScheduler do
  @moduledoc "Schedules authentication-related emails via Oban."

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @doc """
  Schedules user email verification immediately with high priority.
  """
  @spec schedule_email_verification(term(), String.t()) :: :ok | {:error, String.t()}
  def schedule_email_verification(user_id, verification_url) do
    result =
      %{
        "action" => "send_email_verification",
        "user_id" => user_id,
        "verification_url" => verification_url
      }
      |> EmailWorker.new(
        queue: :emails,
        # Highest priority for auth emails
        priority: 0,
        unique: [
          # 2 minutes uniqueness window for auth emails
          period: 120,
          fields: [:args, :queue],
          keys: [:action, :user_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Email verification job scheduled", user_id: user_id)
        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Email verification job already exists, skipping duplicate",
          user_id: user_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule email verification",
          user_id: user_id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules password reset email immediately with high priority.
  """
  @spec schedule_password_reset(term(), String.t()) :: :ok | {:error, String.t()}
  def schedule_password_reset(user_id, reset_url) do
    result =
      %{
        "action" => "send_password_reset",
        "user_id" => user_id,
        "reset_url" => reset_url
      }
      |> EmailWorker.new(
        queue: :emails,
        # Highest priority for auth emails
        priority: 0,
        unique: [
          # 2 minutes uniqueness window
          period: 120,
          fields: [:args, :queue],
          keys: [:action, :user_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Password reset email job scheduled", user_id: user_id)
        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Password reset email job already exists, skipping duplicate",
          user_id: user_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule password reset email",
          user_id: user_id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end
end
