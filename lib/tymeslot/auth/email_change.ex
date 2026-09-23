defmodule Tymeslot.Auth.EmailChange do
  @moduledoc """
  Handles email change requests, verification, and cancellation.

  Orchestrates the multi-step email change flow: validating the request,
  persisting tokens, scheduling notification emails, and confirming the
  change via a verification link.

  Every function fails the same way, `{:error, {reason, message}}`: `reason`
  is an atom a caller can branch on (for a request, the form field the error
  belongs to), `message` is translated and ready to show.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset

  alias Tymeslot.Auth.{
    AccountTokens,
    Session,
    UserQueries,
    UserSessionQueries,
    UserTokenQueries,
    Validation
  }

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Repo
  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.Token
  alias Tymeslot.Utils.{ChangesetUtils, UrlBuilder}

  require Logger

  @type error :: {:error, {atom(), String.t()}}

  @doc """
  Requests an email change for a user.
  Validates password, creates token, stores pending email, and sends verification emails.

  A failure's reason is the form field it belongs to, `:current_password` or
  `:new_email`.
  """
  @spec request_email_change(term(), String.t(), String.t()) ::
          {:ok, term(), String.t()} | {:error, {:current_password | :new_email, String.t()}}
  def request_email_change(user, new_email, current_password) do
    with :ok <- Validation.check_current_password(user, current_password),
         :ok <- validate_email_format(new_email),
         :ok <- validate_email_not_same(user.email, new_email),
         {:ok, :available} <- UserQueries.check_email_availability(new_email),
         {:ok, updated_user, token} <-
           AccountTokens.issue(:email_change, user, %{new_email: new_email}) do
      # Queue emails via Oban; do not fail the request if scheduling fails
      _result =
        EmailScheduler.schedule_email_change_emails(
          updated_user.id,
          new_email,
          UrlBuilder.email_change_url(token),
          Token.hash_token(token)
        )

      {:ok, updated_user,
       dgettext("auth", "Verification email sent to %{email}", email: new_email)}
    else
      {:error, :invalid_password} ->
        {:error, {:current_password, dgettext("auth", "Current password is incorrect")}}

      {:error, :missing_password} ->
        {:error, {:current_password, dgettext("auth", "Password is required")}}

      {:error, :same_email} ->
        {:error, {:new_email, dgettext("auth", "New email must be different from current email")}}

      {:error, :taken} ->
        {:error, {:new_email, email_taken_message()}}

      {:error, %Changeset{} = changeset} ->
        {:error, {:new_email, request_changeset_message(changeset)}}

      {:error, reason} when is_binary(reason) ->
        {:error, {:new_email, reason}}
    end
  end

  @doc """
  Verifies and completes an email change using the verification token.
  Uses a database transaction to ensure atomicity.

  A failure's reason is `:invalid_token`, `:token_expired` or
  `:changeset_error`.
  """
  @spec verify_email_change(String.t()) :: {:ok, Ecto.Schema.t(), String.t()} | error()
  def verify_email_change(token) when is_binary(token) do
    case verify_email_change_in_transaction(token) do
      {:ok, result} ->
        # After successful commit, disconnect any live sockets bound to the
        # now-revoked sessions, then enqueue confirmation emails.
        Enum.each(result.revoked_session_hashes, &Session.disconnect_session_hash/1)

        _result =
          EmailScheduler.schedule_email_change_confirmations(
            result.user.id,
            result.old_email,
            result.user.email
          )

        {:ok, result.user,
         dgettext("auth", "Email changed successfully. Please sign in with your new email.")}

      {:error, :invalid_token} ->
        {:error, {:invalid_token, dgettext("auth", "Invalid or expired verification link")}}

      {:error, :token_expired} ->
        {:error, {:token_expired, dgettext("auth", "Verification link has expired")}}

      {:error, %Changeset{} = changeset} ->
        {:error, {:changeset_error, format_changeset_error(changeset)}}
    end
  end

  @doc """
  Cancels a pending email change request. A failure's reason is
  `:changeset_error`.
  """
  @spec cancel_email_change(Ecto.Schema.t()) :: {:ok, Ecto.Schema.t(), String.t()} | error()
  def cancel_email_change(user) do
    case UserTokenQueries.cancel_email_change(user) do
      {:ok, updated_user} ->
        Logger.info("Email change cancelled", user_id: updated_user.id)
        {:ok, updated_user, dgettext("auth", "Email change request cancelled")}

      {:error, %Changeset{} = changeset} ->
        {:error, {:changeset_error, format_changeset_error(changeset)}}
    end
  end

  # --- Private helpers ---

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

  # The token row is locked for the length of the transaction, so two clicks
  # on the same link cannot both apply the change.
  defp verify_email_change_in_transaction(token) do
    Repo.transaction(fn ->
      with {:ok, user} <- AccountTokens.fetch(:email_change, token, lock: true),
           {:ok, updated_user} <- AccountTokens.consume(:email_change, user) do
        # Invalidate all existing sessions for security. Capture the token
        # hashes before deleting so the caller can disconnect their live
        # sockets *after* this transaction commits — never from inside it.
        revoked_session_hashes =
          UserSessionQueries.list_user_session_token_hashes(updated_user.id)

        UserSessionQueries.delete_user_sessions(updated_user.id)

        Logger.info("Email change verified successfully", user_id: updated_user.id)

        %{
          user: updated_user,
          old_email: user.email,
          revoked_session_hashes: revoked_session_hashes
        }
      else
        {:error, :token_expired, _user} -> Repo.rollback(:token_expired)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The availability pre-check can lose a race to a concurrent request for the
  # same address; the unique index on `pending_email` then rejects the write.
  # Either way the user is told the same thing.
  defp request_changeset_message(%Changeset{errors: errors} = changeset) do
    case Keyword.get(errors, :pending_email) do
      {_message, opts} when is_list(opts) ->
        if opts[:constraint] == :unique or opts[:validation] == :unsafe_unique,
          do: email_taken_message(),
          else: format_changeset_error(changeset)

      nil ->
        format_changeset_error(changeset)
    end
  end

  defp email_taken_message, do: dgettext("auth", "Email address is already in use")

  defp format_changeset_error(%Changeset{} = changeset) do
    ChangesetUtils.get_first_error(changeset)
  end
end
