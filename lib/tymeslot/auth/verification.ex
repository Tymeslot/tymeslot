defmodule Tymeslot.Auth.Verification do
  @moduledoc """
  Handles user verification processes.
  """

  @behaviour Tymeslot.Infrastructure.VerificationBehaviour

  require Logger

  alias Tymeslot.Auth.{AccountTokens, UserSchema}
  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.{RateLimiter, SecurityLogger, Token}
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Helpers.ClientIP

  @type verification_result ::
          {:ok, term()} | {:error, atom()} | {:error, :rate_limited, String.t()}
  @type socket_or_conn :: Phoenix.LiveView.Socket.t() | Plug.Conn.t()

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
  Verifies a user based on the provided token or user ID.

  ## When passing a token (String)
  Looks up the user by token, checks if the token is expired, and marks the user as verified.

  ## When passing a user_id (Integer)
  Directly marks the user as verified without token validation (useful for testing).
  """
  @impl Tymeslot.Infrastructure.VerificationBehaviour
  @spec verify_user(String.t() | integer()) :: verification_result()
  def verify_user(token) when is_binary(token) do
    with {:ok, _user, verified_user} <- verify_by_token(token) do
      {:ok, verified_user}
    end
  end

  def verify_user(user_id) when is_integer(user_id) do
    with {:ok, user} <- fetch_user(user_id, "marking as verified") do
      mark_user_as_verified(user)
    end
  end

  # Returns the user as the token found them (still carrying `signup_ip`)
  # alongside the verified user.
  defp verify_by_token(token) do
    case AccountTokens.fetch(:verification, token) do
      {:ok, user} ->
        with {:ok, verified_user} <- verify_fetched_user(user) do
          {:ok, user, verified_user}
        end

      {:error, :invalid_token} = error ->
        Logger.warning("Email verification failed - invalid token")
        AccountLogging.log_operation_failure("verification", "token", :invalid_token)
        error

      {:error, :token_expired, user} ->
        Logger.warning("Email verification failed - token expired")
        AccountLogging.log_operation_failure("email_verification", user.id, :token_expired)
        {:error, :token_expired}
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
  Initiates the email verification process for a user, rate-limited by IP.
  """
  @impl Tymeslot.Infrastructure.VerificationBehaviour
  @spec verify_user_email(socket_or_conn(), term(), map()) :: verification_result()
  def verify_user_email(socket_or_conn, user, _profile_params) do
    send_within_rate_limit(socket_or_conn, user)
  end

  @doc """
  Resends the verification email, rate-limited by IP.
  """
  @impl Tymeslot.Infrastructure.VerificationBehaviour
  @spec resend_verification_email(socket_or_conn(), term()) :: verification_result()
  def resend_verification_email(socket_or_conn, user) do
    send_within_rate_limit(socket_or_conn, user)
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
  @spec resend_verification_email_by_email(String.t() | nil, socket_or_conn()) ::
          :ok | {:error, :rate_limited, String.t()}
  def resend_verification_email_by_email(email, socket_or_conn) do
    ip_address = extract_ip_address(socket_or_conn)

    case RateLimiter.check_verification_ip_rate_limit(ip_address) do
      :ok ->
        email |> unverified_user() |> resend_quietly(socket_or_conn)

      {:error, :rate_limited, message} ->
        SecurityLogger.log_rate_limit_violation(nil, "email_verification", %{
          ip_address: ip_address
        })

        {:error, :rate_limited, message}
    end
  end

  defp unverified_user(nil), do: nil

  defp unverified_user(email) do
    case Config.user_queries_module().get_user_by_email(email) do
      {:ok, %{verified_at: nil} = user} -> user
      _verified_or_unknown -> nil
    end
  end

  defp resend_quietly(nil, _socket_or_conn), do: :ok

  defp resend_quietly(user, socket_or_conn) do
    case RateLimiter.check_verification_user_rate_limit(user.id) do
      :ok ->
        with {:error, reason} <- do_verify_user_email(socket_or_conn, user) do
          Logger.error("Verification resend failed", user_id: user.id, reason: inspect(reason))
        end

        :ok

      {:error, :rate_limited, _message} ->
        SecurityLogger.log_rate_limit_violation(user.id, "email_verification", %{
          ip_address: extract_ip_address(socket_or_conn)
        })

        :ok
    end
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

  # The initial send and the resend are the same operation as far as the limiter
  # is concerned: they share a bucket, a rejection message, and an audit entry.
  defp send_within_rate_limit(socket_or_conn, user) do
    ip_address = extract_ip_address(socket_or_conn)

    case RateLimiter.check_verification_rate_limit(user.id, ip_address) do
      :ok ->
        do_verify_user_email(socket_or_conn, user)

      {:error, :rate_limited, message} ->
        SecurityLogger.log_rate_limit_violation(user.id, "email_verification", %{
          ip_address: ip_address
        })

        {:error, :rate_limited, message}
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

  defp do_verify_user_email(socket_or_conn, user) do
    ip_address = extract_ip_address(socket_or_conn)

    # Persist the token first so it is valid in the database before the job runs.
    # The job carries the token's hash; the worker discards it at send time if a
    # newer request has since rotated the stored token, so an in-flight or
    # retrying job can never deliver an invalidated link.
    with {:ok, updated_user, token} <- issue_verification_token(user.id, ip_address),
         {:ok, _status} <-
           send_verification_email(
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

  defp send_verification_email(user, verification_url, token_hash) do
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

  defp extract_ip_address(socket_or_conn) do
    ClientIP.get(socket_or_conn)
  end
end
