defmodule Tymeslot.Auth.PasswordReset do
  @moduledoc """
  Handles password reset functionality for user accounts.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Auth.{
    AccountTokens,
    Helpers.AccountLogging,
    RateLimit,
    Session,
    UserSchema,
    Validation
  }

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, RateLimiter, SecurityLogger, Token}
  alias Tymeslot.Utils.UrlBuilder

  @doc """
  Initiates the password reset process for a given email.

  ## Parameters
    - email: String.t() (user email)
    - opts: Keyword list; `:ip` and `:user_agent` identify the requester for
      the rate limit and its audit entry

  ## Returns
    - `{:ok, :reset_initiated, message}` for every well-formed address within
      the rate limit, whether it belongs to a password account, an account
      that signs in through a provider, or no account at all. The reply is
      byte-identical across the three; what differs is only the email the
      address's owner receives (a reset link, a note that there is no password
      to reset, or nothing).
    - `{:error, :invalid_input | :rate_limited, message}` otherwise, which
      depends only on the input and the requester, never on the account
  """
  @spec initiate_reset(String.t(), keyword()) ::
          {:ok, :reset_initiated, String.t()}
          | {:error, :invalid_input | :rate_limited, String.t()}
  def initiate_reset(email, opts \\ []) do
    with {:ok, validated_email} <- validate_email_format(email),
         :ok <- check_reset_rate_limit(validated_email, opts) do
      process_password_reset_secure(validated_email)
    else
      {:error, reason, message} -> {:error, reason, message}
    end
  end

  defp check_reset_rate_limit(email, opts) do
    RateLimit.check(RateLimiter.check_password_reset_rate_limit(email, opts[:ip]),
      event: "password_reset",
      identifier: email,
      ip: opts[:ip],
      user_agent: opts[:user_agent]
    )
  end

  # Every account state gets the same reply, and the explanation, where there
  # is one, goes to the mailbox: only the address's owner can read it.
  #
  # Timing is kept equal by giving every branch the same dominant cost, one
  # bcrypt operation, paid here rather than inside each branch so a branch
  # added later cannot forget it. The work left in the branches (a token write,
  # an Oban insert, or nothing) is small beside it.
  defp process_password_reset_secure(email) do
    Password.no_user_verify()

    email
    |> Config.user_queries_module().get_user_by_email()
    |> handle_password_reset_attempt(email)

    {:ok, :reset_initiated,
     dgettext(
       "auth",
       "If an account exists with this email address, password reset instructions have been sent."
     )}
  end

  defp handle_password_reset_attempt({:error, :not_found}, email) do
    AccountLogging.log_operation_failure("password_reset", email, :user_not_found)
  end

  defp handle_password_reset_attempt({:ok, %{provider: provider} = user}, _email)
       when provider in [nil, "email"] do
    process_regular_user_reset(user)
  end

  defp handle_password_reset_attempt({:ok, user}, _email), do: notify_no_password(user)

  defp validate_email_format(email) do
    case Validation.validate_email(email) do
      {:ok, validated} -> {:ok, validated}
      {:error, msg} -> {:error, :invalid_input, msg}
    end
  end

  defp process_regular_user_reset(user) do
    # Persist the token first so it is valid in the database before the job runs.
    # The job carries the token's hash; the worker discards it at send time if a
    # newer request has since rotated the stored token, so an in-flight or
    # retrying job can never deliver an invalidated link.
    with {:ok, updated_user, token} <- persist_reset_token_and_log(user),
         {:ok, _status} <-
           schedule_reset_email(
             updated_user,
             UrlBuilder.password_reset_url(token),
             Token.hash_token(token)
           ) do
      {:ok, :email_sent,
       dgettext("auth", "Password reset instructions have been sent to your email.")}
    else
      {:error, :token_storage_failed} ->
        {:error, :server_error,
         dgettext("auth", "Unable to send password reset email. Please try again later.")}

      {:error, reason} ->
        Logger.error("Failed to send password reset email",
          user_id: user.id,
          email_masked: SecurityLogger.mask_email(user.email),
          reason: inspect(reason),
          event: :password_reset_email_failed
        )

        {:error, :server_error,
         dgettext("auth", "Unable to send password reset email. Please try again later.")}
    end
  end

  defp persist_reset_token_and_log(user) do
    case AccountTokens.issue(:reset, user) do
      {:ok, updated_user, token} ->
        # Logged at persist time — the email is scheduled separately afterwards, so
        # this records token storage only, not delivery (mirrors the verification flow).
        Logger.info("Password reset token stored",
          user_id: updated_user.id,
          email_masked: SecurityLogger.mask_email(updated_user.email),
          event: :password_reset_token_persisted
        )

        AccountLogging.log_password_reset(updated_user, "initiated")

        {:ok, updated_user, token}

      {:error, _error_reason} ->
        AccountLogging.log_operation_failure(
          "password_reset",
          user.email,
          :token_storage_failed,
          %{user_id: user.id}
        )

        {:error, :token_storage_failed}
    end
  end

  defp schedule_reset_email(user, reset_url, token_hash) do
    case EmailScheduler.schedule_password_reset(user.id, reset_url, token_hash) do
      {:ok, :scheduled} ->
        {:ok, :scheduled}

      {:ok, :duplicate} ->
        Logger.info("Password reset email already queued; updated with fresh token",
          user_id: user.id,
          email_masked: SecurityLogger.mask_email(user.email),
          event: :password_reset_email_deduplicated
        )

        {:ok, :duplicate}

      {:error, reason} ->
        Logger.error("Failed to schedule password reset email",
          user_id: user.id,
          email_masked: SecurityLogger.mask_email(user.email),
          reason: inspect(reason),
          event: :password_reset_email_failed
        )

        {:error, reason}
    end
  end

  # An account that signs in through a provider has no password to reset. Its
  # owner is told so by email, with a sign-in link; the screen says nothing.
  defp notify_no_password(user) do
    AccountLogging.log_operation_failure("password_reset", user.email, :oauth_user, %{
      user_id: user.id,
      provider: user.provider
    })

    case EmailScheduler.schedule_no_password_to_reset(user.id) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule no-password notice",
          user_id: user.id,
          reason: inspect(reason),
          event: :password_reset_no_password_notice_failed
        )

        :error
    end
  end

  @doc """
  Verifies a password reset token without consuming it.

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure
  """
  @spec verify_token(String.t()) ::
          {:ok, UserSchema.t(), String.t()} | {:error, atom(), String.t()}
  def verify_token(token) do
    case fetch_reset_token(token) do
      {:ok, user} -> {:ok, user, dgettext("auth", "Token verified successfully.")}
      {:error, reason, message} -> {:error, reason, message}
    end
  end

  @doc """
  Resets the password for a user.

  ## Parameters
    - token: String.t() (password reset token)
    - new_password: String.t() (new password)
    - password_confirmation: String.t() (password confirmation)
    - opts: Keyword list; `:ip` keys the per-address limit on attempts, and
      it and `:user_agent` are recorded on the audit entry the completed reset
      emits

  ## Returns
    - {:ok, user, message} on success
    - {:error, reason, message} on failure
  """
  @spec reset_password(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, UserSchema.t(), String.t()}
          | {:error, atom(), String.t()}
  def reset_password(token, new_password, password_confirmation, opts) do
    RateLimit.with_limit(
      RateLimiter.check_password_reset_submit_rate_limit(opts[:ip]),
      [event: "password_reset_submit", ip: opts[:ip], user_agent: opts[:user_agent]],
      fn -> do_reset_password(token, new_password, password_confirmation, opts) end
    )
  end

  defp do_reset_password(token, new_password, password_confirmation, opts) do
    case consume_and_update(token, new_password, password_confirmation) do
      {:ok, updated_user} ->
        AccountLogging.log_password_reset(updated_user, "completed")
        :ok = invalidate_all_sessions(updated_user)

        SecurityLogger.log_password_change(updated_user.id, %{
          ip_address: opts[:ip],
          user_agent: opts[:user_agent],
          sessions_invalidated: true
        })

        {:ok, updated_user,
         dgettext(
           "auth",
           "Your password has been reset successfully. Please log in with your new password."
         )}

      {:error, reason, message} ->
        {:error, reason, message}
    end
  end

  # The lookup + update run inside a single transaction with `FOR UPDATE` on
  # the token row so two concurrent requests can't both pass the
  # `used_at IS NULL` check and each apply a password update — without the
  # lock, the later update silently overwrites the earlier one.
  defp consume_and_update(token, new_password, password_confirmation) do
    txn =
      Repo.transaction(fn ->
        with {:ok, user} <- fetch_reset_token(token, lock: true),
             {:ok, _validated} <-
               validate_password_input(new_password, password_confirmation, user),
             {:ok, updated_user} <- perform_password_update(user, new_password) do
          updated_user
        else
          {:error, reason, message} -> Repo.rollback({reason, message})
        end
      end)

    case txn do
      {:ok, user} -> {:ok, user}
      {:error, {reason, message}} -> {:error, reason, message}
    end
  end

  defp fetch_reset_token(token, opts \\ []) do
    case AccountTokens.fetch(:reset, token, opts) do
      {:ok, user} ->
        {:ok, user}

      {:error, :invalid_token} ->
        Logger.warning("Invalid password reset token",
          token: String.slice(token, 0, 8) <> "...",
          event: :password_reset_invalid_token
        )

        {:error, :invalid_token, dgettext("auth", "Invalid or expired password reset token.")}

      {:error, :token_expired, user} ->
        Logger.warning("Password reset token expired",
          user_id: user.id,
          email_masked: SecurityLogger.mask_email(user.email),
          event: :password_reset_token_expired
        )

        {:error, :token_expired,
         dgettext("auth", "Your reset token has expired. Please request a new password reset.")}
    end
  end

  defp validate_password_input(new_password, password_confirmation, user) do
    params = %{"password" => new_password, "password_confirmation" => password_confirmation}

    case Validation.validate_new_password_input(params) do
      {:ok, _sanitized} ->
        {:ok, :validated}

      {:error, errors} ->
        AccountLogging.log_validation_failure("password_reset", user.email, errors, %{
          user_id: user.id
        })

        {:error, :invalid_input, password_error_message(errors)}
    end
  end

  # The password validator's messages are already whole sentences naming their
  # own field ("Password must contain at least one special character"), and the
  # confirmation field is validated against the same rules, so it reports the
  # same failure. Running that through the generic field-prefixing formatter
  # produced "Password Password must contain… Password confirmation Password
  # must contain…". The distinct messages, joined, are what a user can act on.
  defp password_error_message(errors) do
    errors
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp perform_password_update(user, new_password) do
    # Pass raw passwords to let the changeset handle validation and hashing.
    case AccountTokens.consume(:reset, user, %{
           password: new_password,
           password_confirmation: new_password
         }) do
      {:ok, updated_user} ->
        {:ok, updated_user}

      {:error, errors} ->
        Logger.error("Failed to update password",
          user_id: user.id,
          email_masked: SecurityLogger.mask_email(user.email),
          errors: inspect(errors),
          event: :password_reset_update_password_failed
        )

        {:error, :invalid_password,
         dgettext(
           "auth",
           "The password couldn't be updated. Please try again with a different password."
         )}
    end
  end

  # Invalidate all user sessions after password reset for security. Also
  # disconnects any still-connected live sockets so the revocation is immediate.
  defp invalidate_all_sessions(user) do
    Session.revoke_all_sessions(user.id)

    Logger.info("Invalidated all sessions after password reset",
      user_id: user.id,
      email_masked: SecurityLogger.mask_email(user.email),
      event: :sessions_invalidated_password_reset
    )

    :ok
  end
end
