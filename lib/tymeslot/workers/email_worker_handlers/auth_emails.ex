defmodule Tymeslot.Workers.EmailWorkerHandlers.AuthEmails do
  @moduledoc """
  Handles authentication-related email actions: email verification, password reset, and
  email change flows.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries

  @spec handle_email_verification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_email_verification(%{"user_id" => user_id, "verification_url" => verification_url}) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_email_verification(user, verification_url) do
          {:ok, _result} ->
            Logger.info("Queued email verification sent", user_id: user_id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to send email verification",
              user_id: user_id,
              error: inspect(reason)
            )

            {:error, "Failed to send email verification"}
        end

      {:error, :not_found} ->
        Logger.warning("User not found for email verification", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  @spec handle_password_reset(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_password_reset(%{"user_id" => user_id, "reset_url" => reset_url}) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_password_reset(user, reset_url) do
          {:ok, _result} ->
            Logger.info("Queued password reset email sent", user_id: user_id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to send password reset email",
              user_id: user_id,
              error: inspect(reason)
            )

            {:error, "Failed to send password reset email"}
        end

      {:error, :not_found} ->
        Logger.warning("User not found for password reset email", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  @spec handle_email_change_verification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_email_change_verification(%{
        "user_id" => user_id,
        "new_email" => new_email,
        "verification_url" => verification_url
      }) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_email_change_verification(
               user,
               new_email,
               verification_url
             ) do
          {:ok, _result} ->
            Logger.info("Queued email change verification sent",
              user_id: user_id,
              new_email: new_email
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to send email change verification",
              user_id: user_id,
              new_email: new_email,
              error: inspect(reason)
            )

            {:error, "Failed to send email change verification"}
        end

      {:error, :not_found} ->
        Logger.warning("User not found for email change verification", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  @spec handle_email_change_notification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_email_change_notification(%{"user_id" => user_id, "new_email" => new_email}) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_email_change_notification(user, new_email) do
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

            {:error, "Failed to send email change notification"}
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
    with {:ok, user} <- UserQueries.get_user(user_id),
         {old_result, new_result} <-
           email_service_module().send_email_change_confirmations(user, old_email, new_email) do
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

  defp email_service_module do
    Application.get_env(:tymeslot, :email_service_module) ||
      Application.get_env(:tymeslot, :email_service) ||
      Tymeslot.Emails.EmailService
  end
end
