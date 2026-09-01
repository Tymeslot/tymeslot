defmodule Tymeslot.Security.RateLimiter.Auth do
  @moduledoc false

  alias Tymeslot.Security.AccountLockout
  alias Tymeslot.Security.RateLimiter.Helpers

  @signup_limits [
    {"10m", 5, 10 * 60_000},
    {"1h", 8, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 12, 7 * 24 * 60 * 60_000},
    {"1mo", 15, 30 * 24 * 60 * 60_000},
    {"1y", 20, 365 * 24 * 60 * 60_000}
  ]

  @verification_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 20, 7 * 24 * 60 * 60_000},
    {"1mo", 25, 30 * 24 * 60 * 60_000},
    {"1y", 50, 365 * 24 * 60 * 60_000}
  ]

  @password_reset_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 20, 7 * 24 * 60 * 60_000},
    {"1mo", 25, 30 * 24 * 60 * 60_000},
    {"1y", 50, 365 * 24 * 60 * 60_000}
  ]

  @spec check_auth(String.t(), String.t() | nil) :: :ok | {:error, :rate_limited, String.t()}
  def check_auth(email, ip \\ nil) do
    # Normalise so whitespace-padded and case-variant emails share one bucket,
    # preventing " User@X.com " / "user@x.com" bypasses of the login limit.
    downcased_email = email |> String.trim() |> String.downcase()

    with :ok <- AccountLockout.check_lockout_status(downcased_email),
         :ok <-
           Helpers.check_with_logging(
             "login:#{downcased_email}",
             10,
             1_800_000,
             "authentication",
             downcased_email
           ),
         :ok <- check_auth_ip_bucket(ip) do
      :ok
    else
      {:error, :account_throttled, message} -> {:error, :rate_limited, message}
      error -> error
    end
  end

  @spec record_attempt(String.t(), boolean()) :: :ok | {:error, atom(), String.t()}
  def record_attempt(email, success) do
    AccountLockout.check_and_record_attempt(email, success)
  end

  @spec check_signup(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_signup(email, ip) do
    normalized_ip = Helpers.normalize_ip(ip)
    downcased_email = String.downcase(email)

    Helpers.check_multi_bucket_limits([
      {"signup:email:#{downcased_email}", @signup_limits, "signup"},
      {"signup:ip:#{normalized_ip}", @signup_limits, "signup"}
    ])
  end

  @spec check_verification(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_verification(user_id, ip) do
    normalized_ip = Helpers.normalize_ip(ip)

    Helpers.check_multi_bucket_limits([
      {"email_verification:user:#{user_id}", @verification_limits, "email verification"},
      {"email_verification:ip:#{normalized_ip}", @verification_limits, "email verification"}
    ])
  end

  @spec check_password_reset(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_password_reset(email, ip) do
    downcased_email = String.downcase(email)
    normalized_ip = Helpers.normalize_ip(ip)

    Helpers.check_multi_bucket_limits([
      {"password_reset:email:#{downcased_email}", @password_reset_limits, "password reset"},
      {"password_reset:ip:#{normalized_ip}", @password_reset_limits, "password reset"}
    ])
  end

  defp check_auth_ip_bucket(ip) when is_binary(ip) and ip != "" do
    Helpers.check_with_logging(
      "login_ip:#{ip}",
      50,
      1_800_000,
      "authentication (ip)",
      ip
    )
  end

  defp check_auth_ip_bucket(_invalid_ip), do: :ok
end
