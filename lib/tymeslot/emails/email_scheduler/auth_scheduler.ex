defmodule Tymeslot.Emails.EmailScheduler.AuthScheduler do
  @moduledoc "Schedules authentication-related emails via Oban."

  alias Tymeslot.Emails.EmailScheduler.{Helpers, LinkArg}
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @doc """
  Schedules user email verification immediately with high priority.
  """
  @spec schedule_email_verification(term(), String.t(), String.t()) ::
          {:ok, :scheduled | :duplicate} | {:error, String.t()}
  def schedule_email_verification(user_id, verification_url, token_hash) do
    result =
      %{
        "action" => "send_email_verification",
        "user_id" => user_id,
        # Lets the worker discard a job whose token has since been rotated.
        "token_hash" => token_hash
      }
      |> LinkArg.put("verification_url", verification_url)
      |> EmailWorker.new(
        queue: :emails,
        # Highest priority for auth emails
        priority: 0,
        unique: [
          # 2 minutes uniqueness window for auth emails
          period: 120,
          fields: [:args, :queue],
          keys: [:action, :user_id],
          # Only coalesce against a job the worker has NOT yet started. For these
          # states `replace: [:args]` reliably updates the pending job to deliver
          # the freshly rotated token. We deliberately exclude :executing and
          # :retryable: a job already running has read its args into memory, so
          # replacing the row's args cannot change what it delivers — coalescing
          # there would send the old (now-invalidated) token and orphan the link.
          # A resend during that brief window instead enqueues a fresh job and
          # delivers a second valid email; the UX-level resend cooldown bounds the
          # volume.
          states: [:scheduled, :available]
        ],
        # On conflict with a not-yet-started job, replace its args so it delivers
        # the token we just persisted, keeping the queued job and the stored
        # token hash in lock-step.
        replace: [:args]
      )
      |> Oban.insert()

    case result do
      {:ok, %Oban.Job{conflict?: true}} ->
        Logger.info("Email verification job already exists, skipping duplicate",
          user_id: user_id
        )

        {:ok, :duplicate}

      {:ok, _job} ->
        Logger.info("Email verification job scheduled", user_id: user_id)
        {:ok, :scheduled}

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
  @spec schedule_password_reset(term(), String.t(), String.t()) ::
          {:ok, :scheduled | :duplicate} | {:error, String.t()}
  def schedule_password_reset(user_id, reset_url, token_hash) do
    result =
      %{
        "action" => "send_password_reset",
        "user_id" => user_id,
        # Lets the worker discard a job whose token has since been rotated.
        "token_hash" => token_hash
      }
      |> LinkArg.put("reset_url", reset_url)
      |> EmailWorker.new(
        queue: :emails,
        # Highest priority for auth emails
        priority: 0,
        unique: [
          # 2 minutes uniqueness window
          period: 120,
          fields: [:args, :queue],
          keys: [:action, :user_id],
          # Only coalesce against a job the worker has NOT yet started. For these
          # states `replace: [:args]` reliably updates the pending job to deliver
          # the freshly rotated token. We deliberately exclude :executing and
          # :retryable: a job already running has read its args into memory, so
          # replacing the row's args cannot change what it delivers — coalescing
          # there would send the old (now-invalidated) token and orphan the link.
          # A resend during that brief window instead enqueues a fresh job and
          # delivers a second valid email; the UX-level resend cooldown bounds the
          # volume.
          states: [:scheduled, :available]
        ],
        # On conflict with a not-yet-started job, replace its args so it delivers
        # the token we just persisted, keeping the queued job and the stored
        # token hash in lock-step.
        replace: [:args]
      )
      |> Oban.insert()

    case result do
      {:ok, %Oban.Job{conflict?: true}} ->
        Logger.info("Password reset email job already exists, skipping duplicate",
          user_id: user_id
        )

        {:ok, :duplicate}

      {:ok, _job} ->
        Logger.info("Password reset email job scheduled", user_id: user_id)
        {:ok, :scheduled}

      {:error, reason} ->
        Logger.error("Failed to schedule password reset email",
          user_id: user_id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules the note sent when a password reset is requested for an account
  that signs in through a provider and so has no password to reset.
  """
  @spec schedule_no_password_to_reset(term()) ::
          {:ok, :scheduled | :duplicate} | {:error, String.t()}
  def schedule_no_password_to_reset(user_id),
    do: schedule_account_notice("send_no_password_to_reset", user_id)

  @doc """
  Schedules the note sent to an account's owner when someone tries to sign up
  with their address.
  """
  @spec schedule_signup_attempt_notice(term()) ::
          {:ok, :scheduled | :duplicate} | {:error, String.t()}
  def schedule_signup_attempt_notice(user_id),
    do: schedule_account_notice("send_signup_attempt_notice", user_id)

  # Notices that carry no token: the job needs only the recipient, and the links
  # in them lead to public pages, so the worker builds them at send time. A
  # second request inside the window coalesces with the first rather than
  # sending the owner the same note twice.
  defp schedule_account_notice(action, user_id) do
    result =
      %{"action" => action, "user_id" => user_id}
      |> EmailWorker.new(
        queue: :emails,
        priority: 0,
        unique: [
          period: 120,
          fields: [:args, :queue],
          keys: [:action, :user_id],
          states: [:scheduled, :available, :executing]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, %Oban.Job{conflict?: true}} ->
        {:ok, :duplicate}

      {:ok, _job} ->
        Logger.info("Account notice scheduled", action: action, user_id: user_id)
        {:ok, :scheduled}

      {:error, reason} ->
        Logger.error("Failed to schedule account notice",
          action: action,
          user_id: user_id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end
end
