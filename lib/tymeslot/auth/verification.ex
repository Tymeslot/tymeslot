defmodule Tymeslot.Auth.Verification do
  @moduledoc """
  Handles user verification processes.
  """

  require Logger

  alias Tymeslot.Auth.{AccountTokens, RateLimit, UserSchema}
  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Repo
  alias Tymeslot.Security.{RateLimiter, Token}
  alias Tymeslot.Utils.UrlBuilder

  @type verification_result ::
          {:ok, term()} | {:error, atom()} | {:error, :rate_limited, String.t()}

  @doc """
  Issues a fresh verification token for a user, replacing any earlier one,
  and returns the raw token for the emailed link.
  """
  @spec issue_verification_token(integer(), String.t() | nil) ::
          {:ok, UserSchema.t(), String.t()} | {:error, :user_not_found | :token_storage_failed}
  def issue_verification_token(user_id, ip_address \\ nil) do
    with {:ok, user} <- fetch_user(user_id, "storing verification token"),
         {:ok, updated_user, token} <-
           AccountTokens.issue(:verification, user, %{ip_address: ip_address}) do
      {:ok, updated_user, token}
    else
      {:error, :user_not_found} = error ->
        error

      {:error, _changeset} ->
        Logger.error("Token storage failed", user_id: user_id)
        {:error, :token_storage_failed}
    end
  end

  @doc """
  Verifies the user behind an email verification `token`: looks the user up
  by token, refuses an expired one, and marks the user as verified.
  """
  @spec verify_user(String.t()) :: verification_result()
  def verify_user(token) when is_binary(token) do
    with {:ok, _user, verified_user} <- verify_by_token(token) do
      {:ok, verified_user}
    end
  end

  # Returns the user as the token found them (still carrying `signup_ip`)
  # alongside the verified user. The token's row is locked while it is
  # spent, so two clicks on the same link cannot both verify.
  defp verify_by_token(token) do
    result =
      Repo.transaction(fn ->
        case AccountTokens.fetch(:verification, token, lock: true) do
          {:ok, user} ->
            case verify_fetched_user(user) do
              {:ok, verified_user} -> {user, verified_user}
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, :invalid_token} ->
            Logger.warning("Email verification failed - invalid token")
            AccountLogging.log_operation_failure("verification", "token", :invalid_token)
            Repo.rollback(:invalid_token)

          {:error, :token_expired, user} ->
            Logger.warning("Email verification failed - token expired")
            AccountLogging.log_operation_failure("email_verification", user.id, :token_expired)
            Repo.rollback(:token_expired)
        end
      end)

    case result do
      {:ok, {user, verified_user}} -> {:ok, user, verified_user}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies the email address behind `token` and decides whether the person who
  opened the link may be signed straight in.

  Auto-login is granted only when the link is completed from the IP address
  the account signed up from (localhost spellings treated as one), so a link
  forwarded to, or intercepted by, someone else verifies the address without
  handing over a session.
  """
  @spec verify_email_and_maybe_login(String.t(), String.t() | nil) ::
          {:ok, term(), :auto_login | :manual} | {:error, atom()}
  def verify_email_and_maybe_login(token, request_ip) when is_binary(token) do
    with {:ok, user, verified_user} <- verify_by_token(token) do
      {:ok, verified_user, login_mode(user.signup_ip, request_ip)}
    end
  end

  defp login_mode(nil, _request_ip), do: :manual

  defp login_mode(signup_ip, request_ip) do
    if normalise_localhost(signup_ip) == normalise_localhost(request_ip),
      do: :auto_login,
      else: :manual
  end

  defp normalise_localhost(ip) when ip in ["127.0.0.1", "::1", "0:0:0:0:0:0:0:1"],
    do: "localhost"

  defp normalise_localhost(ip), do: ip

  @doc """
  Sends `user` a fresh verification link, within the per-account and
  per-address limits the initial send and every resend share.

  `ip` is the requesting client's address; it keys the limit and is stored
  with the token, so a link completed from the same address may sign in.
  """
  @spec send_verification_email(UserSchema.t(), String.t() | nil) :: verification_result()
  def send_verification_email(user, ip) do
    RateLimit.with_limit(
      RateLimiter.check_verification_rate_limit(user.id, ip),
      [event: "email_verification", identifier: user.id, ip: ip],
      fn ->
        issue_and_send(user, ip)
      end
    )
  end

  @doc """
  Resends the verification email for `email`, answering the same way whatever
  the address turns out to be.

  The address bucket is charged first, before anything is looked up, so the
  only refusal a caller can see depends on who is asking and never on the
  account. After that the reply is `:ok` for an unverified account (which is
  sent a fresh link), a verified one, an unknown address, `nil` (no account to
  resend for), and an account that has used up its own resend allowance: the
  mailbox is the only place the difference shows.

  Callers pass an address the requester has already proved is theirs (the
  session-bound unverified user), never one typed into a form.
  """
  @spec resend_verification_email_by_email(String.t() | nil, String.t() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def resend_verification_email_by_email(email, ip) do
    RateLimit.with_limit(
      RateLimiter.check_verification_ip_rate_limit(ip),
      [event: "email_verification", identifier: nil, ip: ip],
      fn ->
        email |> unverified_user() |> resend_quietly(ip)
      end
    )
  end

  @doc """
  Sends an unverified account a fresh verification link after its owner
  proved the password at sign-in, within the usual per-account and per-address
  limits.

  Silent by design: sign-in answers an unverified account exactly as it
  answers a wrong password, so this is how a genuine new user who lost the
  first email still gets one. Whatever happens here is logged, never returned.
  """
  @spec send_link_after_sign_in(UserSchema.t(), String.t() | nil) :: :ok
  def send_link_after_sign_in(%UserSchema{verified_at: nil} = user, ip_address) do
    with {:error, reason} <- send_verification_email(user, ip_address) do
      Logger.error("Verification link after sign-in failed",
        user_id: user.id,
        reason: inspect(reason)
      )
    end

    :ok
  end

  def send_link_after_sign_in(_verified_user, _ip_address), do: :ok

  defp unverified_user(nil), do: nil

  defp unverified_user(email) do
    case Config.user_queries_module().get_user_by_email(email) do
      {:ok, %{verified_at: nil} = user} -> user
      _verified_or_unknown -> nil
    end
  end

  defp resend_quietly(nil, _ip), do: :ok

  defp resend_quietly(user, ip) do
    RateLimit.with_limit(
      RateLimiter.check_verification_user_rate_limit(user.id),
      [event: "email_verification", identifier: user.id, ip: ip],
      fn ->
        with {:error, reason} <- issue_and_send(user, ip) do
          Logger.error("Verification resend failed", user_id: user.id, reason: inspect(reason))
        end
      end
    )

    :ok
  end

  # Private functions

  @spec verify_fetched_user(UserSchema.t()) :: verification_result()
  defp verify_fetched_user(user) do
    case mark_user_as_verified(user) do
      {:ok, updated_user} ->
        Logger.info("Email verification successful", user_id: updated_user.id)
        {:ok, updated_user}

      {:error, reason} = error ->
        Logger.error("Email verification failed", reason: inspect(reason))
        # The token resolved and had not expired, only the update failed, so
        # the token may still be valid and unconsumed.
        AccountLogging.log_operation_failure("email_verification", user.id, reason)
        error
    end
  end

  @spec mark_user_as_verified(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, atom()}
  defp mark_user_as_verified(user) do
    case AccountTokens.consume(:verification, user) do
      {:ok, updated_user} ->
        AccountLogging.log_user_verified(updated_user, "email")
        :telemetry.execute([:tymeslot, :auth, :email_verified], %{count: 1}, %{})
        {:ok, updated_user}

      {:error, _changeset} ->
        AccountLogging.log_operation_failure("verification", user.id, :verification_failed)
        {:error, :verification_failed}
    end
  end

  defp fetch_user(user_id, context) do
    case Config.user_queries_module().get_user(user_id) do
      {:ok, user} ->
        {:ok, user}

      _other ->
        Logger.error("User not found", during: context, user_id: user_id)
        {:error, :user_not_found}
    end
  end

  defp issue_and_send(user, ip_address) do
    # Persist the token first so it is valid in the database before the job runs.
    # The job carries the token's hash; the worker discards it at send time if a
    # newer request has since rotated the stored token, so an in-flight or
    # retrying job can never deliver an invalidated link.
    with {:ok, updated_user, token} <- issue_verification_token(user.id, ip_address),
         {:ok, _status} <-
           schedule_verification_email(
             updated_user,
             UrlBuilder.email_verification_url(token),
             Token.hash_token(token)
           ) do
      {:ok, updated_user}
    else
      {:error, :token_storage_failed} ->
        Logger.error("Failed to store verification token", user_id: user.id)
        {:error, :token_storage_failed}

      {:error, :user_not_found} ->
        Logger.error("Unknown error during email verification", user_id: user.id)
        {:error, :unknown}

      {:error, _reason} ->
        Logger.error("Failed to send verification email", user_id: user.id)
        {:error, :email_send_failed}
    end
  end

  defp schedule_verification_email(user, verification_url, token_hash) do
    # Use the email worker to send the verification email asynchronously.
    case EmailScheduler.schedule_email_verification(user.id, verification_url, token_hash) do
      {:ok, :scheduled} ->
        Logger.info("Verification email job scheduled", user_id: user.id)
        {:ok, :scheduled}

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      {:error, reason} ->
        Logger.error("Failed to schedule verification email",
          user_id: user.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end
