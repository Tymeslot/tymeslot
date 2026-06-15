defmodule Tymeslot.Auth.Authentication do
  @moduledoc """
  Handles user authentication for email/password login.
  """

  alias Tymeslot.Auth.ErrorFormatter
  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Auth.{UserQueries, UserSessionQueries}
  alias Tymeslot.Infrastructure.StructuredLogger
  alias Tymeslot.Security.{InputProcessor, Password, RateLimiter, SecurityLogger}

  @type conn :: Plug.Conn.t()

  @doc """
  Authenticates a user with the given email and password.

  ## Parameters
    - email: String.t() (user email)
    - password: String.t() (user password)
    - opts: Keyword list

  ## Returns
    - {:ok, user, flash_info} on success
    - {:error, reason, flash_error} on failure

  """
  @spec authenticate_user(String.t(), String.t(), keyword()) ::
          {:ok, term(), String.t() | nil}
          | {:error, atom(), String.t()}
          | {:error, :invalid_input, map()}
  def authenticate_user(email, password, opts \\ []) do
    case validate_login_params(email, password) do
      :ok ->
        check_rate_limit_and_authenticate(email, password, opts)

      {:error, errors} ->
        {:error, :invalid_input, errors}
    end
  end

  defp check_rate_limit_and_authenticate(email, password, opts) do
    case RateLimiter.check_auth_rate_limit(email, opts[:ip_address]) do
      :ok ->
        authenticate_with_password(email, password, opts)

      {:error, :rate_limited, message} ->
        SecurityLogger.log_rate_limit_violation(email, "authentication", %{
          ip_address: opts[:ip_address],
          user_agent: opts[:user_agent]
        })

        {:error, :rate_limit_exceeded, message}
    end
  end

  defp authenticate_with_password(email, password, opts) do
    case UserQueries.get_user_by_email(email) do
      {:error, :not_found} ->
        # Perform a dummy hash check to prevent timing-based email enumeration.
        # Without this, an attacker can distinguish "user not found" (fast) from
        # "wrong password" (slow bcrypt verify) by measuring response time.
        Password.no_user_verify()

        AccountLogging.log_operation_failure("authentication", email, :not_found)

        SecurityLogger.log_authentication_attempt(email, false, "user_not_found", %{
          ip_address: opts[:ip_address],
          user_agent: opts[:user_agent]
        })

        {:error, :not_found, ErrorFormatter.format_auth_error(:not_found)}

      {:ok, user} ->
        verify_user_password(user, password, opts)
    end
  end

  defp verify_user_password(user, password, opts) do
    cond do
      user.provider not in [nil, "email"] ->
        log_auth_attempt(user, :oauth_user, opts)
        RateLimiter.record_auth_attempt(user.email, false)
        {:error, :oauth_user, ErrorFormatter.format_auth_error(:oauth_user)}

      user.verified_at == nil ->
        log_auth_attempt(user, :email_not_verified, opts)
        RateLimiter.record_auth_attempt(user.email, false)
        {:error, :email_not_verified, ErrorFormatter.format_auth_error(:email_not_verified)}

      verify_password(user, password) ->
        log_auth_attempt(user, :success, opts)

        :telemetry.execute([:tymeslot, :auth, :login_completed], %{count: 1}, %{
          method: "password"
        })

        RateLimiter.record_auth_attempt(user.email, true)
        {:ok, user, "Login successful."}

      true ->
        log_auth_attempt(user, :invalid_password, opts)
        RateLimiter.record_auth_attempt(user.email, false)
        {:error, :invalid_password, ErrorFormatter.format_auth_error(:invalid_password)}
    end
  end

  defp log_auth_attempt(user, :success, opts) do
    StructuredLogger.log_auth_event(:login_success, user.id, %{
      email: user.email,
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    })

    AccountLogging.log_operation_success("authentication", user.email, %{user_id: user.id})

    SecurityLogger.log_authentication_attempt(user.email, true, "success", %{
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    })
  end

  defp log_auth_attempt(user, reason, opts) do
    StructuredLogger.log_auth_event(:login_failure, user.id, %{
      email: user.email,
      reason: reason,
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    })

    AccountLogging.log_operation_failure("authentication", user.email, reason, %{
      user_id: user.id
    })

    SecurityLogger.log_authentication_attempt(user.email, false, to_string(reason), %{
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    })
  end

  @doc """
  Retrieves a user by their session token.

  Returns the full user record if found, otherwise nil.
  """
  @spec get_user_by_session_token(String.t()) :: term() | nil
  def get_user_by_session_token(token) do
    UserSessionQueries.get_user_by_session_token(token)
  end

  # Private functions

  defp validate_login_params(email, password) do
    errors =
      case InputProcessor.validate_field(email, :email) do
        {:ok, _sanitized} -> %{}
        {:error, msg} -> %{email: msg}
      end

    errors =
      cond do
        is_nil(password) or password == "" ->
          Map.put(errors, :password, "Password is required")

        byte_size(password) > 1024 ->
          Map.put(errors, :password, "Password is too long")

        true ->
          errors
      end

    if map_size(errors) == 0, do: :ok, else: {:error, errors}
  end

  defp verify_password(user, password) do
    Password.verify_password(password, user.password_hash)
  end
end
