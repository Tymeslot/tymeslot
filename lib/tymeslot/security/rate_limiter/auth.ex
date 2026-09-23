defmodule Tymeslot.Security.RateLimiter.Auth do
  @moduledoc false

  use Gettext, backend: TymeslotWeb.Gettext

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

  # Per email and client address: the budget a single source gets against one
  # account. Keyed on the pair so that failures from one address can never lock
  # the owner out from another.
  @login_pair_limit 10
  # Per email across every address: only a run spread over many addresses
  # reaches it, so it caps distributed guessing without handing a single
  # attacker a way to lock an account out.
  @login_email_ceiling 50
  @login_window_ms 1_800_000

  @spec check_auth(String.t(), String.t() | nil) :: :ok | {:error, :rate_limited, String.t()}
  def check_auth(email, ip) do
    # Normalise so whitespace-padded and case-variant emails share one bucket,
    # preventing " User@X.com " / "user@x.com" bypasses of the login limit.
    downcased_email = normalise_email(email)
    pair = login_pair(downcased_email, ip)

    with :ok <- AccountLockout.check_lockout_status(pair),
         :ok <-
           Helpers.check_with_logging(
             "login:#{pair}",
             @login_pair_limit,
             @login_window_ms,
             "authentication",
             downcased_email
           ),
         :ok <-
           Helpers.check_with_logging(
             "login:#{downcased_email}",
             @login_email_ceiling,
             @login_window_ms,
             "authentication (account)",
             downcased_email
           ),
         :ok <- check_auth_ip_bucket(ip) do
      :ok
    else
      {:error, :account_throttled, message} -> {:error, :rate_limited, message}
      error -> error
    end
  end

  @spec record_attempt(String.t(), String.t() | nil, boolean()) ::
          :ok | {:error, atom(), String.t()}
  def record_attempt(email, ip, success) do
    email
    |> normalise_email()
    |> login_pair(ip)
    |> AccountLockout.check_and_record_attempt(success)
  end

  defp normalise_email(email), do: email |> String.trim() |> String.downcase()

  # The email comes first so a bucket key still reads as the account it guards.
  defp login_pair(downcased_email, ip), do: "#{downcased_email}|#{Helpers.normalize_ip(ip)}"

  @spec check_signup(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_signup(email, ip) do
    normalized_ip = Helpers.normalize_ip(ip)
    downcased_email = String.downcase(email)
    action = dgettext("errors", "signup attempts")

    Helpers.check_multi_bucket_limits([
      {"signup:email:#{downcased_email}", @signup_limits, "signup", action},
      {"signup:ip:#{normalized_ip}", @signup_limits, "signup", action}
    ])
  end

  @spec check_verification(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_verification(user_id, ip) do
    normalized_ip = Helpers.normalize_ip(ip)
    action = dgettext("errors", "verification emails")

    Helpers.check_multi_bucket_limits([
      {"email_verification:user:#{user_id}", @verification_limits, "email verification", action},
      {"email_verification:ip:#{normalized_ip}", @verification_limits, "email verification",
       action}
    ])
  end

  @spec check_password_reset(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_password_reset(email, ip) do
    downcased_email = String.downcase(email)
    normalized_ip = Helpers.normalize_ip(ip)
    action = dgettext("errors", "password reset requests")

    Helpers.check_multi_bucket_limits([
      {"password_reset:email:#{downcased_email}", @password_reset_limits, "password reset",
       action},
      {"password_reset:ip:#{normalized_ip}", @password_reset_limits, "password reset", action}
    ])
  end

  @spec check_email_change_verify(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_email_change_verify(client_ip) do
    Helpers.check_with_logging(
      "email_change_verify:#{client_ip}",
      30,
      60_000,
      "email change verification",
      client_ip
    )
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
