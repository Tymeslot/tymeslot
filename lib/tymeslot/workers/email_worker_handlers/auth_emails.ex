defmodule Tymeslot.Workers.EmailWorkerHandlers.AuthEmails do
  @moduledoc """
  Handles authentication-related email actions: email verification, password reset, and
  email change flows.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Utils.UrlBuilder
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome

  @spec handle_email_verification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_email_verification(%{"user_id" => user_id} = args) do
    with {:ok, verification_url} <- fetch_link(args, "verification_url"),
         {:ok, user} <- fetch_user(user_id, "email verification") do
      if token_superseded?(args, user.verification_token) do
        Logger.info("Skipping superseded email verification job", user_id: user_id)
        {:discard, "Verification token superseded by a newer request"}
      else
        deliver_email_verification(user, verification_url)
      end
    end
  end

  defp deliver_email_verification(user, verification_url) do
    case Config.email_service_module().send_email_verification(user, verification_url) do
      {:ok, _result} ->
        Logger.info("Queued email verification sent", user_id: user.id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to send email verification",
          user_id: user.id,
          error: inspect(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to send email verification")
    end
  end

  @spec handle_password_reset(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_password_reset(%{"user_id" => user_id} = args) do
    with {:ok, reset_url} <- fetch_link(args, "reset_url"),
         {:ok, user} <- fetch_user(user_id, "password reset email") do
      if token_superseded?(args, user.reset_token_hash) do
        Logger.info("Skipping superseded password reset job", user_id: user_id)
        {:discard, "Reset token superseded by a newer request"}
      else
        deliver_password_reset(user, reset_url)
      end
    end
  end

  defp deliver_password_reset(user, reset_url) do
    case Config.email_service_module().send_password_reset(user, reset_url) do
      {:ok, _result} ->
        Logger.info("Queued password reset email sent", user_id: user.id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to send password reset email",
          user_id: user.id,
          error: inspect(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to send password reset email")
    end
  end

  @spec handle_no_password_to_reset(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_no_password_to_reset(%{"user_id" => user_id}) do
    with {:ok, user} <- fetch_user(user_id, "no-password-to-reset notice") do
      Config.email_service_module().send_no_password_to_reset(user, sign_in_url())
      |> notice_outcome(user, "no-password-to-reset notice")
    end
  end

  @spec handle_signup_attempt_notice(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_signup_attempt_notice(%{"user_id" => user_id}) do
    with {:ok, user} <- fetch_user(user_id, "sign-up attempt notice") do
      Config.email_service_module().send_signup_attempt_notice(
        user,
        sign_in_url(),
        UrlBuilder.build_url("/auth/reset-password")
      )
      |> notice_outcome(user, "sign-up attempt notice")
    end
  end

  defp sign_in_url, do: UrlBuilder.build_url("/auth/login")

  defp notice_outcome({:ok, _result}, user, label) do
    Logger.info("Queued account notice sent", notice: label, user_id: user.id)
    :ok
  end

  defp notice_outcome({:error, reason}, user, label) do
    Logger.error("Failed to send account notice",
      notice: label,
      user_id: user.id,
      error: inspect(reason)
    )

    DeliveryOutcome.from_error(reason, "Failed to send #{label}")
  end

  @spec handle_email_change_verification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_email_change_verification(%{"user_id" => user_id, "new_email" => new_email} = args) do
    with {:ok, verification_url} <- fetch_link(args, "verification_url"),
         {:ok, user} <- fetch_user(user_id, "email change verification") do
      if token_superseded?(args, user.email_change_token_hash) do
        Logger.info("Skipping superseded email change verification job", user_id: user_id)
        {:discard, "Email change token superseded or revoked"}
      else
        deliver_email_change_verification(user, new_email, verification_url)
      end
    end
  end

  defp deliver_email_change_verification(user, new_email, verification_url) do
    case Config.email_service_module().send_email_change_verification(
           user,
           new_email,
           verification_url
         ) do
      {:ok, _result} ->
        Logger.info("Queued email change verification sent",
          user_id: user.id,
          new_email: new_email
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to send email change verification",
          user_id: user.id,
          new_email: new_email,
          error: inspect(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to send email change verification")
    end
  end

  @spec handle_email_change_notification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_email_change_notification(%{"user_id" => user_id, "new_email" => new_email}) do
    case UserQueries.get_user_with_profile(user_id) do
      {:ok, user} ->
        case Config.email_service_module().send_email_change_notification(user, new_email) do
          {:ok, _result} ->
            Logger.info("Queued email change notification sent",
              user_id: user_id,
              new_email: new_email
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to send email change notification",
              user_id: user_id,
              new_email: new_email,
              error: inspect(reason)
            )

            DeliveryOutcome.from_error(reason, "Failed to send email change notification")
        end

      {:error, :not_found} ->
        Logger.warning("User not found for email change notification", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  @spec handle_email_change_confirmations(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_email_change_confirmations(%{
        "user_id" => user_id,
        "old_email" => old_email,
        "new_email" => new_email
      }) do
    with {:ok, user} <- UserQueries.get_user_with_profile(user_id),
         {old_result, new_result} <-
           Config.email_service_module().send_email_change_confirmations(
             user,
             old_email,
             new_email
           ) do
      organizer_success = match?({:ok, _result}, old_result)
      new_success = match?({:ok, _result}, new_result)

      Logger.info("Email change confirmations sent",
        user_id: user_id,
        old_sent: organizer_success,
        new_sent: new_success
      )

      if organizer_success and new_success do
        :ok
      else
        {:error, "One or more emails failed"}
      end
    else
      {:error, :not_found} ->
        Logger.warning("User not found for email change confirmations", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  # A link that cannot be read back (tampered, or encrypted under a key since
  # rotated away) can never become readable on a retry, so the job is dropped.
  defp fetch_link(args, key) do
    case LinkArg.fetch(args, key) do
      {:ok, url} ->
        {:ok, url}

      :error ->
        Logger.error("Email job carries no readable link",
          action: args["action"],
          user_id: args["user_id"]
        )

        {:discard, "Link missing or unreadable"}
    end
  end

  defp fetch_user(user_id, label) do
    case UserQueries.get_user_with_profile(user_id) do
      {:ok, user} ->
        {:ok, user}

      {:error, :not_found} ->
        Logger.warning("User not found for auth email", email: label, user_id: user_id)
        {:discard, "User not found"}
    end
  end

  # A job's token has been superseded when the hash it was enqueued with no
  # longer matches the hash currently stored for the user — i.e. a later request
  # rotated the token after this job was queued, or a credential change
  # revoked it (the stored hash is then nil). Jobs enqueued before token
  # hashes were tracked carry no "token_hash" and are always delivered.
  defp token_superseded?(args, current_hash) do
    case Map.get(args, "token_hash") do
      nil -> false
      job_hash -> job_hash != current_hash
    end
  end
end
