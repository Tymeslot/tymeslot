defmodule Tymeslot.Auth.Authentication do
  @moduledoc """
  Handles user authentication for email/password login.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth.ErrorFormatter
  alias Tymeslot.Auth.Helpers.AccountLogging
  alias Tymeslot.Auth.{UserQueries, Verification}
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

  A wrong password, an unknown address, an account with no password and an
  unverified account (even with its correct password) all return the same
  generic error, which also points a recent sign-up at their inbox. An
  unverified account whose password was proved is sent a fresh verification
  link, quietly; see `Verification.send_link_after_sign_in/2`.
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

  # The password is checked before anything about the account is revealed.
  # "Not verified" and "social login" are only disclosed to someone who has
  # just proved they hold the password; everyone else gets the same generic
  # error, at the same bcrypt cost, as a wrong password on any other account.
  defp verify_user_password(user, password, opts) do
    if password_matches?(user, password) do
      authorise_login(user, opts)
    else
      log_auth_attempt(user, :invalid_password, opts)
      record_auth_attempt(user, false, opts)
      {:error, :invalid_password, ErrorFormatter.format_auth_error(:invalid_password)}
    end
  end

  defp authorise_login(user, opts) do
    cond do
      user.provider not in [nil, "email"] ->
        # A proved password is never a failed guess, so it clears the lockout
        # counter rather than adding to it.
        record_auth_attempt(user, true, opts)
        log_auth_attempt(user, :oauth_user, opts)
        {:error, :oauth_user, ErrorFormatter.format_auth_error(:oauth_user)}

      # Anyone can sign up an unverified account for an address they do not
      # own, so admitting to one, even to the holder of its password, would
      # tell them the address was free. It is answered as a wrong password,
      # and counted as one so the lockout cannot tell them apart either. The
      # genuine owner is sent a fresh link instead, which only they can read.
      user.verified_at == nil ->
        log_auth_attempt(user, :email_not_verified, opts)
        record_auth_attempt(user, false, opts)
        Verification.send_link_after_sign_in(user, opts[:ip_address])
        {:error, :invalid_password, ErrorFormatter.format_auth_error(:invalid_password)}

      true ->
        record_auth_attempt(user, true, opts)
        log_auth_attempt(user, :success, opts)

        :telemetry.execute([:tymeslot, :auth, :login_completed], %{count: 1}, %{
          method: "password"
        })

        {:ok, user, dgettext("auth", "Login successful.")}
    end
  end

  # Records the attempt against the account lockout tracker and audits the
  # moment the account crosses the throttle threshold.
  #
  # `check_auth_rate_limit/2` runs *before* this, as a read-only pre-check
  # (`AccountLockout.check_lockout_status/1`) that returns an error without
  # recording anything once the failure count reaches the throttle threshold
  # (10 in the last hour). Under strictly sequential brute force that
  # short-circuits `authenticate_with_password/3` before this function can
  # record another failure, so the count freezes at the threshold and this
  # emits once per hour, as the 1-hour sliding window ages old attempts out
  # and throttling re-triggers. Throttling is the whole defence by design;
  # see `Tymeslot.Security.AccountLockout` for why there is no harder tier.
  #
  # That is not the concurrent case: the pre-check is read-only and separate
  # from the write below, so every request already past the pre-check when
  # the threshold is crossed records its own failure here and emits its own
  # `account_lockout` event. This function has no idempotency guard, so a
  # burst of concurrent failed logins against one account produces one
  # `account_lockout` audit entry per in-flight attempt, not one per lockout.
  defp record_auth_attempt(user, success, opts) do
    case RateLimiter.record_auth_attempt(user.email, opts[:ip_address], success) do
      {:error, :account_throttled, _message} ->
        SecurityLogger.log_account_lockout(user.email, "account_throttled", %{
          user_id: user.id,
          ip_address: opts[:ip_address],
          user_agent: opts[:user_agent]
        })

      _other ->
        :ok
    end
  end

  defp log_auth_attempt(user, :success, opts) do
    StructuredLogger.log_auth_event(:login_success, user.id, %{
      email_masked: SecurityLogger.mask_email(user.email),
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
      email_masked: SecurityLogger.mask_email(user.email),
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

  # An account without a password (signed up through a social login) still
  # pays for a dummy hash, so it cannot be told apart by response time.
  defp password_matches?(%{password_hash: hash}, password) when is_binary(hash),
    do: Password.verify_password(password, hash)

  defp password_matches?(_user, _password), do: Password.no_user_verify()
end
