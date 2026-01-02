defmodule Tymeslot.Auth.Verification do
  @moduledoc """
  Handles user verification processes.
  """

  @behaviour Tymeslot.Infrastructure.VerificationBehaviour

  require Logger

  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.{RateLimiter, Token}
  alias Tymeslot.Utils.UrlBuilder
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Helpers.ClientIP

  @type verification_result ::
          {:ok, term()} | {:error, atom()} | {:error, :rate_limited, String.t()}
  @type socket_or_conn :: Phoenix.LiveView.Socket.t() | Plug.Conn.t()

  @doc """
  Stores a verification token for a user.
  """
  @spec store_verification_token(integer(), String.t(), DateTime.t(), String.t() | nil) ::
          {:ok, term()} | {:error, atom()}
  def store_verification_token(user_id, token, _expiry, ip_address \\ nil) do
    case Config.user_queries_module().get_user(user_id) do
      nil ->
        Logger.error("User not found when storing verification token for user_id=#{user_id}")
        {:error, :user_not_found}

      {:ok, user} ->
        case Config.user_queries_module().set_verification_token(user, token, ip_address) do
          {:ok, updated_user} ->
            {:ok, updated_user}

          {:error, _changeset} ->
            Logger.error("Token storage failed for user_id=#{user_id}")
            {:error, :token_storage_failed}
        end

      {:error, :not_found} ->
        Logger.error("User not found when storing verification token for user_id=#{user_id}")
        {:error, :user_not_found}

      user when is_struct(user) ->
        case Config.user_queries_module().set_verification_token(user, token, ip_address) do
          {:ok, updated_user} ->
            {:ok, updated_user}

          {:error, _changeset} ->
            Logger.error("Token storage failed for user_id=#{user_id}")
            {:error, :token_storage_failed}
        end
    end
  end

  @doc """
  Verifies a user based on the provided token or user ID.

  ## When passing a token (String)
  Looks up the user by token, checks if the token is expired, and marks the user as verified.

  ## When passing a user_id (Integer)
  Directly marks the user as verified without token validation (useful for testing).
  """
  @impl true
  @spec verify_user(String.t() | integer()) :: verification_result()
  def verify_user(token) when is_binary(token) do
    with {:ok, user} <- fetch_user_by_token(token),
         :ok <- check_token_expiration(user),
         {:ok, updated_user} <- mark_user_as_verified(user.id) do
      Logger.info("Email verification successful for user_id=#{updated_user.id}")
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
        Logger.error("Email verification failed - unexpected error: #{inspect(reason)}")
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
  @impl true
  @spec verify_user_email(socket_or_conn(), term(), map()) :: verification_result()
  def verify_user_email(socket_or_conn, user, _profile_params) do
    ip_address = extract_ip_address(socket_or_conn)

    case RateLimiter.check_verification_rate_limit(user.id, ip_address) do
      :ok ->
        do_verify_user_email(socket_or_conn, user)

      {:error, :rate_limited, message} ->
        {:error, :rate_limited, message}
    end
  end

  @doc """
  Handles the verification token submitted by the user (controller action).
  Returns only tagged tuples, no Plug.Conn.
  """
  @impl true
  @spec verify_user_token(String.t()) :: {:ok, term()} | {:error, atom()}
  def verify_user_token(token), do: verify_user(token)

  @doc """
  Resends the verification email, rate-limited by IP.
  """
  @impl true
  @spec resend_verification_email(socket_or_conn(), term()) :: verification_result()
  def resend_verification_email(socket_or_conn, user) do
    ip_address = extract_ip_address(socket_or_conn)

    case RateLimiter.check_verification_rate_limit(user.id, ip_address) do
      :ok ->
        do_verify_user_email(socket_or_conn, user)

      {:error, :rate_limited, message} ->
        {:error, :rate_limited, message}
    end
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
        Logger.warning("Attempted to resend verification for non-existent email: #{email}")
        {:error, :user_not_found}

      other ->
        Logger.error("Unexpected return from get_user_by_email/1: #{inspect(other)}")
        {:error, :user_not_found}
    end
  end

  # Private functions

  @spec fetch_user_by_token(String.t()) :: {:ok, term()} | {:error, :invalid_token}
  defp fetch_user_by_token(token) do
    case Config.user_queries_module().get_user_by_verification_token(token) do
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
         sent_at when not is_nil(sent_at) <- user.verification_sent_at,
         expiry <- DateTime.add(sent_at, 2 * 3600, :second),
         :gt <- DateTime.compare(expiry, DateTime.utc_now()) do
      :ok
    else
      _ -> {:error, :token_expired}
    end
  end

  @spec mark_user_as_verified(integer()) :: {:ok, term()} | {:error, atom()}
  defp mark_user_as_verified(user_id) do
    case Config.user_queries_module().get_user(user_id) do
      nil ->
        Logger.error("User not found when marking as verified: user_id=#{user_id}")
        {:error, :user_not_found}

      {:error, :not_found} ->
        Logger.error("User not found when marking as verified: user_id=#{user_id}")
        {:error, :user_not_found}

      {:ok, user} ->
        case Config.user_queries_module().verify_user(user) do
          {:ok, updated_user} ->
            AccountLogging.log_user_verified(updated_user, "email")
            {:ok, updated_user}

          {:error, _changeset} ->
            AccountLogging.log_operation_failure("verification", user_id, :verification_failed)
            {:error, :verification_failed}
        end

      user when is_struct(user) ->
        case Config.user_queries_module().verify_user(user) do
          {:ok, updated_user} ->
            AccountLogging.log_user_verified(updated_user, "email")
            {:ok, updated_user}

          {:error, _changeset} ->
            AccountLogging.log_operation_failure("verification", user_id, :verification_failed)
            {:error, :verification_failed}
        end
    end
  end

  defp do_verify_user_email(socket_or_conn, user) do
    {token, expiry, _} = Token.generate_email_verification_token(user.id)
    verification_url = build_verification_url(socket_or_conn, token)
    ip_address = extract_ip_address(socket_or_conn)

    case store_verification_token(user.id, token, expiry, ip_address) do
      {:ok, updated_user} ->
        case send_verification_email(updated_user, verification_url) do
          {:ok, _pid} ->
            {:ok, updated_user}

          {:error, _} ->
            Logger.error("Failed to send verification email to user_id=#{user.id}")
            {:error, :email_send_failed}
        end

      {:error, :token_storage_failed} ->
        Logger.error("Failed to store verification token for user_id=#{user.id}")
        {:error, :token_storage_failed}

      {:error, _} ->
        Logger.error("Unknown error during email verification for user_id=#{user.id}")
        {:error, :unknown}
    end
  end

  defp build_verification_url(%Phoenix.LiveView.Socket{}, verification_token) do
    UrlBuilder.email_verification_url(verification_token)
  end

  defp build_verification_url(%Plug.Conn{} = _conn, verification_token) do
    UrlBuilder.email_verification_url(verification_token)
  end

  defp build_verification_url(_socket_or_conn, verification_token) do
    # Fallback for tests or when neither socket nor conn is available
    UrlBuilder.email_verification_url(verification_token)
  end

  defp send_verification_email(user, verification_url) do
    # Use the email worker to send the verification email asynchronously
    case EmailWorker.schedule_email_verification(user.id, verification_url) do
      :ok ->
        Logger.info("Verification email job scheduled for user_id=#{user.id}")
        {:ok, self()}

      {:error, reason} ->
        Logger.error(
          "Failed to schedule verification email for user_id=#{user.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp extract_ip_address(socket_or_conn) do
    # ClientIP.get/1 always returns a binary (string)
    ClientIP.get(socket_or_conn)
  rescue
    _ ->
      # Be defensive: do not leak details, and keep return type consistent.
      "unknown"
  end
end
