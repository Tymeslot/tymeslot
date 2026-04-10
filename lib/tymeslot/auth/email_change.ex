defmodule Tymeslot.Auth.EmailChange do
  @moduledoc """
  Handles email change requests, verification, and cancellation.

  Orchestrates the multi-step email change flow: validating the request,
  persisting tokens, scheduling notification emails, and confirming the
  change via a verification link.
  """

  alias Ecto.Changeset

  alias Tymeslot.Auth.{UserQueries, UserSessionQueries, UserTokenQueries}
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Repo
  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.{Password, Token}
  alias Tymeslot.Utils.{ChangesetUtils, UrlBuilder}

  require Logger

  @doc """
  Requests an email change for a user.
  Validates password, creates token, stores pending email, and sends verification emails.
  """
  @spec request_email_change(term(), String.t(), String.t()) ::
          {:ok, term(), String.t()} | {:error, String.t()}
  def request_email_change(user, new_email, current_password) do
    with :ok <- verify_current_password(user, current_password),
         :ok <- validate_email_format(new_email),
         :ok <- validate_email_not_same(user.email, new_email),
         {:ok, :available} <- UserQueries.check_email_availability(new_email),
         token_raw <- Token.generate_token(),
         {:ok, updated_user} <- UserTokenQueries.request_email_change(user, new_email, token_raw) do
      verification_url = UrlBuilder.email_change_url(token_raw)

      # Queue emails via Oban; do not fail the request if scheduling fails
      _result =
        EmailScheduler.schedule_email_change_emails(
          updated_user.id,
          new_email,
          verification_url
        )

      {:ok, updated_user, "Verification email sent to #{new_email}"}
    else
      {:error, :invalid_password} ->
        {:error, "Current password is incorrect"}

      {:error, :same_email} ->
        {:error, "New email must be different from current email"}

      {:error, :taken} ->
        {:error, "Email address is already in use"}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  @doc """
  Verifies and completes an email change using the verification token.
  Uses a database transaction to ensure atomicity.
  """
  @spec verify_email_change(String.t()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, atom(), String.t()}
  def verify_email_change(token) when is_binary(token) do
    with {:ok, user} <- UserTokenQueries.get_user_by_email_change_token(token),
         :ok <- check_email_change_token_validity(user),
         old_email <- user.email,
         new_email <- user.pending_email,
         {:ok, result} <- verify_email_change_in_transaction(user, old_email, new_email) do
      # After successful commit, enqueue confirmation emails
      _result =
        EmailScheduler.schedule_email_change_confirmations(
          result.user.id,
          old_email,
          new_email
        )

      {:ok, result.user, "Email changed successfully. Please sign in with your new email."}
    else
      {:error, :not_found} ->
        {:error, :invalid_token, "Invalid or expired verification link"}

      {:error, :token_expired} ->
        {:error, :token_expired, "Verification link has expired"}

      {:error, %Changeset{} = changeset} ->
        {:error, :changeset_error, format_changeset_error(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, :unknown, reason}

      _unknown_error ->
        {:error, :unknown, "Failed to verify email change"}
    end
  end

  @doc """
  Cancels a pending email change request.
  """
  @spec cancel_email_change(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t(), String.t()} | {:error, String.t()}
  def cancel_email_change(user) do
    case UserTokenQueries.cancel_email_change(user) do
      {:ok, updated_user} ->
        Logger.info("Email change cancelled", user_id: updated_user.id)
        {:ok, updated_user, "Email change request cancelled"}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error(changeset)}
    end
  end

  # --- Private helpers ---

  defp verify_current_password(user, password) do
    if Password.verify_password(password, user.password_hash) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  defp validate_email_format(email) do
    case EmailValidator.validate(email) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp validate_email_not_same(current_email, new_email) do
    if String.downcase(String.trim(current_email)) == String.downcase(String.trim(new_email)) do
      {:error, :same_email}
    else
      :ok
    end
  end

  defp verify_email_change_in_transaction(user, old_email, new_email) do
    Repo.transaction(fn ->
      case UserTokenQueries.confirm_email_change(user) do
        {:ok, updated_user} ->
          # Invalidate all existing sessions for security
          UserSessionQueries.delete_user_sessions(updated_user.id)

          Logger.info("Email change verified successfully",
            user_id: updated_user.id,
            old_email: old_email,
            new_email: new_email
          )

          %{user: updated_user}

        {:error, changeset} ->
          Repo.rollback({:changeset_error, format_changeset_error(changeset)})
      end
    end)
  end

  defp check_email_change_token_validity(user) do
    case user.email_change_sent_at do
      nil ->
        {:error, :token_expired}

      sent_at ->
        # Token expires after 24 hours
        expiry_time = DateTime.add(sent_at, 24 * 60 * 60, :second)

        if DateTime.compare(DateTime.utc_now(), expiry_time) == :lt do
          :ok
        else
          {:error, :token_expired}
        end
    end
  end

  defp format_changeset_error(%Changeset{} = changeset) do
    ChangesetUtils.get_first_error(changeset)
  end
end
