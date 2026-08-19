defmodule Tymeslot.Auth.Verification do
  @moduledoc """
  Handles user verification processes.
  """

  @behaviour Tymeslot.Infrastructure.VerificationBehaviour

  require Logger

  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.{RateLimiter, SecurityLogger, Token}
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Helpers.ClientIP

  @type verification_result ::
          {:ok, term()} | {:error, atom()} | {:error, :rate_limited, String.t()}
  @type socket_or_conn :: Phoenix.LiveView.Socket.t() | Plug.Conn.t()

  # Verification links stay valid for 24 hours from the moment they are sent.
  @token_validity_seconds 24 * 3600

  @doc """
  Stores a verification token for a user.
  """
  @spec store_verification_token(integer(), String.t(), DateTime.t(), String.t() | nil) ::
          {:ok, term()} | {:error, atom()}
  def store_verification_token(user_id, token, _expiry, ip_address \\ nil) do
    case Config.user_queries_module().get_user(user_id) do
      {:ok, user} ->
        case Config.user_token_queries_module().set_verification_token(user, token, ip_address) do
          {:ok, updated_user} ->
            {:ok, updated_user}

          {:error, _changeset} ->
            Logger.error("Token storage failed", user_id: user_id)
            {:error, :token_storage_failed}
        end

      _other ->
        Logger.error("User not found when storing verification token", user_id: user_id)
        {:error, :user_not_found}
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
    with {:ok, user} <- fetch_user_by_token(token),
         :ok <- check_token_expiration(user),
         {:ok, updated_user} <- mark_user_as_verified(user.id) do
      Logger.info("Email verification successful", user_id: updated_user.id)
      {:ok, updated_user}
    else
      {:error, :token_expired} = error ->
        Logger.warning("Email verification failed - token expired")
        AccountLogging.log_operation_failure("email_verification", token, :token_expired)
        error

      {:error, :invalid_token} = error ->
        Logger.warning("Email verification failed - invalid token")
        AccountLogging.log_operation_failure("email_verification", token, :invalid_token)
        error

      {:error, reason} = error ->
        Logger.error("Email verification failed", reason: inspect(reason))
        AccountLogging.log_operation_failure("email_verification", token, reason)
        error
    end
  end

  def verify_user(user_id) when is_integer(user_id) do
    mark_user_as_verified(user_id)
  end

  @doc """
  Initiates the email verification process for a user, rate-limited by IP.
  """
  @impl Tymeslot.Infrastructure.VerificationBehaviour
  @spec verify_user_email(socket_or_conn(), term(), map()) :: verification_result()
  def verify_user_email(socket_or_conn, user, _profile_params) do
    send_within_rate_limit(socket_or_conn, user)
  end

  @doc """
  Handles the verification token submitted by the user (controller action).
  Returns only tagged tuples, no Plug.Conn.
  """
  @impl Tymeslot.Infrastructure.VerificationBehaviour
  @spec verify_user_token(String.t()) :: {:ok, term()} | {:error, atom()}
  def verify_user_token(token), do: verify_user(token)

  @doc """
  Resends the verification email, rate-limited by IP.
  """
  @impl Tymeslot.Infrastructure.VerificationBehaviour
  @spec resend_verification_email(socket_or_conn(), term()) :: verification_result()
  def resend_verification_email(socket_or_conn, user) do
    send_within_rate_limit(socket_or_conn, user)
  end

  @doc """
  Resends verification email by email address.
  Looks up the user first, then resends if found.
  Used by AuthLive for email-based resending.
  """
  @spec resend_verification_email_by_email(String.t(), socket_or_conn()) :: verification_result()
  def resend_verification_email_by_email(email, socket_or_conn) do
    case Config.user_queries_module().get_user_by_email(email) do
      {:ok, user} ->
        resend_verification_email(socket_or_conn, user)

      {:error, :not_found} ->
        Logger.warning("Attempted to resend verification for non-existent email", email: email)
        {:error, :user_not_found}

      other ->
        Logger.error("Unexpected return from get_user_by_email/1", result: inspect(other))
        {:error, :user_not_found}
    end
  end

  # Private functions

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

  @spec fetch_user_by_token(String.t()) :: {:ok, term()} | {:error, :invalid_token}
  defp fetch_user_by_token(token) do
    case Config.user_token_queries_module().get_user_by_verification_token(token) do
      {:error, :not_found} ->
        AccountLogging.log_operation_failure("verification", "token", :invalid_token)
        {:error, :invalid_token}

      {:ok, user} ->
        {:ok, user}
    end
  end

  @spec check_token_expiration(term()) :: :ok | {:error, :token_expired}
  defp check_token_expiration(user) do
    with nil <- user.verification_token_used_at,
         %DateTime{} = sent_at <- user.verification_sent_at,
         expiry <- DateTime.add(sent_at, @token_validity_seconds, :second),
         :gt <- DateTime.compare(expiry, DateTime.utc_now()) do
      :ok
    else
      _other -> {:error, :token_expired}
    end
  end

  @spec mark_user_as_verified(integer()) :: {:ok, term()} | {:error, atom()}
  defp mark_user_as_verified(user_id) do
    case Config.user_queries_module().get_user(user_id) do
      {:ok, user} ->
        case Config.user_queries_module().verify_user(user) do
          {:ok, updated_user} ->
            AccountLogging.log_user_verified(updated_user, "email")
            :telemetry.execute([:tymeslot, :auth, :email_verified], %{count: 1}, %{})
            {:ok, updated_user}

          {:error, _changeset} ->
            AccountLogging.log_operation_failure("verification", user_id, :verification_failed)
            {:error, :verification_failed}
        end

      _other ->
        Logger.error("User not found when marking as verified", user_id: user_id)
        {:error, :user_not_found}
    end
  end

  defp do_verify_user_email(socket_or_conn, user) do
    {token, expiry, _purpose} = Token.generate_email_verification_token(user.id)
    verification_url = build_verification_url(socket_or_conn, token)
    token_hash = Token.hash_token(token)
    ip_address = extract_ip_address(socket_or_conn)

    # Persist the token first so it is valid in the database before the job runs.
    # The job carries the token's hash; the worker discards it at send time if a
    # newer request has since rotated the stored token, so an in-flight or
    # retrying job can never deliver an invalidated link.
    with {:ok, updated_user} <- persist_verification_token(user, token, expiry, ip_address),
         {:ok, _status} <- send_verification_email(updated_user, verification_url, token_hash) do
      {:ok, updated_user}
    else
      {:error, :token_storage_failed} ->
        Logger.error("Failed to store verification token", user_id: user.id)
        {:error, :token_storage_failed}

      {:error, :unknown} ->
        Logger.error("Unknown error during email verification", user_id: user.id)
        {:error, :unknown}

      {:error, _reason} ->
        Logger.error("Failed to send verification email", user_id: user.id)
        {:error, :email_send_failed}
    end
  end

  defp persist_verification_token(user, token, expiry, ip_address) do
    case store_verification_token(user.id, token, expiry, ip_address) do
      {:ok, updated_user} ->
        {:ok, updated_user}

      {:error, :token_storage_failed} ->
        {:error, :token_storage_failed}

      {:error, _reason} ->
        {:error, :unknown}
    end
  end

  defp build_verification_url(_socket_or_conn, verification_token) do
    UrlBuilder.email_verification_url(verification_token)
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
