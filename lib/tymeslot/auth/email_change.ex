defmodule Tymeslot.Auth.EmailChange do
  @moduledoc """
  Handles email change requests, verification, and cancellation.

  Orchestrates the multi-step email change flow: validating the request,
  persisting tokens, scheduling notification emails, and confirming the
  change via a verification link.

  A request is a form submission and fails with `{:error, %{field =>
  message}}`, so every field's problem can be shown at once. Verifying and
  cancelling fail with `{:error, {reason, message}}`: `reason` is an atom a
  caller can branch on, `message` is translated and ready to show.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset

  alias Tymeslot.Auth.{
    AccountTokens,
    RateLimit,
    Session,
    UserQueries,
    UserSessionQueries,
    UserTokenQueries,
    Validation
  }

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Repo
  alias Tymeslot.Security.{InputProcessor, RateLimiter, Token}
  alias Tymeslot.Utils.{ChangesetUtils, UrlBuilder}

  require Logger

  @type error :: {:error, {atom(), String.t()}}

  @doc """
  Requests an email change for a user.
  Validates password, creates token, stores pending email, and sends verification emails.

  A failure is `{:error, %{field => message}}`, keyed by the form field each
  message belongs to (`:current_password`, `:new_email`). Malformed input is
  reported for every field at once, before the password is checked.

  `user` only identifies the account: it is re-read under a row lock, so the
  password is checked against the current hash and the request serialises
  with a concurrent password change instead of slipping a token in after it.

  `opts` carries the request context (`:ip`, `:user_agent`). The request is
  held to the login rate limit, since it checks a password; over it the
  result is `{:error, :rate_limited, message}` and nothing is checked.
  """
  @spec request_email_change(term(), term(), term(), keyword()) ::
          {:ok, term(), String.t()}
          | {:error, %{optional(:current_password | :new_email) => String.t()}}
          | {:error, :rate_limited, String.t()}
  def request_email_change(user, new_email, current_password, opts \\ []) do
    RateLimit.with_limit(
      RateLimiter.check_auth_rate_limit(user.email, opts[:ip]),
      [
        event: "email_change",
        identifier: user.email,
        ip: opts[:ip],
        user_agent: opts[:user_agent]
      ],
      fn -> do_request_email_change(user, new_email, current_password) end
    )
  end

  defp do_request_email_change(%{id: user_id}, new_email, current_password) do
    with {:ok, new_email} <- validate_input(new_email, current_password),
         {:ok, updated_user, token} <- issue_in_transaction(user_id, new_email, current_password) do
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
      {:error, errors} when is_map(errors) and not is_struct(errors) ->
        {:error, errors}

      {:error, reason} when reason in [:invalid_password, :missing_password] ->
        {:error, %{current_password: Validation.current_password_message(reason)}}

      {:error, :not_found} ->
        {:error, %{current_password: Validation.current_password_message(:invalid_password)}}

      {:error, :same_email} ->
        {:error, %{new_email: dgettext("auth", "New email must be different from current email")}}

      {:error, :taken} ->
        {:error, %{new_email: email_taken_message()}}

      {:error, %Changeset{} = changeset} ->
        {:error, %{new_email: request_changeset_message(changeset)}}
    end
  end

  # Every field's problem at once, so the form can show them together. The
  # current password is held only to login's presence and length rules.
  defp validate_input(new_email, current_password) do
    email_result =
      InputProcessor.validate_field(new_email, :email, universal_opts: [allow_html: false])

    errors =
      Enum.reduce(
        [email_result, Validation.validate_current_password_input(current_password)],
        %{},
        fn
          {:error, message}, acc when is_binary(message) ->
            Map.put(acc, :new_email, message)

          {:error, reason}, acc when is_atom(reason) ->
            Map.put(acc, :current_password, Validation.current_password_message(reason))

          _ok, acc ->
            acc
        end
      )

    case {errors, email_result} do
      {empty, {:ok, sanitised_email}} when empty == %{} -> {:ok, sanitised_email}
      {errors, _email_result} -> {:error, errors}
    end
  end

  defp issue_in_transaction(user_id, new_email, current_password) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- UserQueries.get_user_for_update(user_id),
             :ok <- Validation.check_current_password(user, current_password),
             :ok <- validate_email_not_same(user.email, new_email),
             {:ok, :available} <- UserQueries.check_email_availability(new_email),
             {:ok, updated_user, token} <-
               AccountTokens.issue(:email_change, user, %{new_email: new_email}) do
          {updated_user, token}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {updated_user, token}} -> {:ok, updated_user, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies and completes an email change using the verification token.
  Uses a database transaction to ensure atomicity.

  A failure's reason is `:rate_limited`, `:invalid_token`, `:token_expired`
  or `:changeset_error`. `opts` carries the request context (`:ip`,
  `:user_agent`), which keys the per-address limit on following links.
  """
  @spec verify_email_change(String.t(), keyword()) ::
          {:ok, Ecto.Schema.t(), String.t()} | error()
  def verify_email_change(token, opts \\ []) when is_binary(token) do
    limit = RateLimiter.check_email_change_verify_rate_limit(opts[:ip])
    context = [event: "email_change_verify", ip: opts[:ip], user_agent: opts[:user_agent]]

    case RateLimit.check(limit, context) do
      :ok -> complete_email_change(token)
      {:error, :rate_limited, message} -> {:error, {:rate_limited, message}}
    end
  end

  defp complete_email_change(token) do
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
