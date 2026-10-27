defmodule Tymeslot.Security.RateLimiter.Auth do
  @moduledoc false

  # Login: three related buckets and a throttle charged only on failure, which
  # is more than one entry of `RateLimiter.Limits` can say. Every other auth
  # limit is in that table.

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.RateLimiter.Helpers
  alias Tymeslot.Security.SecurityLogger

  require Logger

  # Per email and client address: the budget a single source gets against one
  # account. Keyed on the pair so that failures from one address can never lock
  # the owner out from another.
  @login_pair_limit 10
  # Per email across every address: only a run spread over many addresses
  # reaches it, so it caps distributed guessing without handing a single
  # attacker a way to lock an account out.
  @login_email_ceiling 50
  @login_window_ms 1_800_000

  # The failed-login throttle, per email and client address: once a pair has
  # ten failures inside the last hour, `check_auth/2` refuses it until the
  # oldest age out. It is a limiter bucket charged only on failure and cleared
  # on success, so every row it leaves expires with its window and the
  # limiter's periodic clean drops it, whatever the traffic.
  #
  # There is one tier, deliberately. The pre-check in `check_auth/2` is
  # read-only, so once the threshold is reached the login path stops before
  # recording another failure, and a harder tier above it is unreachable by
  # sequential guessing. Making it reachable would mean recording attempts the
  # pre-check already refused, which turns the throttle into a lock anyone who
  # can reach the login form can set off against the account's owner.
  @failed_login_limit 10
  @failed_login_window_ms 3_600_000

  @spec check_auth(String.t(), String.t() | nil) :: :ok | {:error, :rate_limited, String.t()}
  # Refuses without a log line of its own: the auth flows log a refusal once,
  # as a rate_limit_violation security event.
  def check_auth(email, ip) do
    # Normalise so whitespace-padded and case-variant emails share one bucket,
    # preventing " User@X.com " / "user@x.com" bypasses of the login limit.
    downcased_email = normalise_email(email)
    pair = login_pair(downcased_email, ip)

    with :ok <- check_failed_logins(pair),
         :ok <-
           Helpers.check_window("login:#{pair}", @login_pair_limit, @login_window_ms,
             operation: "authentication",
             identifier: downcased_email,
             log: false
           ),
         :ok <-
           Helpers.check_window(
             "login:#{downcased_email}",
             @login_email_ceiling,
             @login_window_ms,
             operation: "authentication (account)",
             identifier: downcased_email,
             log: false
           ) do
      check_auth_ip_bucket(ip)
    end
  end

  @spec record_attempt(String.t(), String.t() | nil, boolean()) ::
          :ok | {:error, :account_throttled, String.t()}
  def record_attempt(email, ip, true) do
    email |> normalise_email() |> login_pair(ip) |> failed_login_key() |> Helpers.clear_bucket()
  end

  def record_attempt(email, ip, false) do
    downcased_email = normalise_email(email)

    # Fires on every failed attempt, so it is the highest-volume line in the
    # auth path under a credential-stuffing run; the address is masked here
    # rather than left to the global metadata filter.
    Logger.info("Failed attempt recorded",
      identifier_masked: SecurityLogger.mask_email(downcased_email)
    )

    # Charged with a limit one below the threshold, so the failure that
    # brings the count to the threshold is itself the one refused, exactly
    # when the pre-check starts refusing.
    key = downcased_email |> login_pair(ip) |> failed_login_key()

    case Helpers.check_rate(key, @failed_login_window_ms, @failed_login_limit - 1) do
      {:allow, _count} -> :ok
      {:deny, _retry_after_ms} -> {:error, :account_throttled, throttled_message()}
    end
  end

  defp check_failed_logins(pair) do
    if Helpers.bucket_count(failed_login_key(pair), @failed_login_window_ms) >=
         @failed_login_limit,
       do: {:error, :rate_limited, throttled_message()},
       else: :ok
  end

  defp failed_login_key(pair), do: "login_fail:#{pair}"

  defp throttled_message,
    do: dgettext("auth", "Too many failed attempts. Please wait before trying again")

  defp normalise_email(email), do: email |> String.trim() |> String.downcase()

  # The email comes first so a bucket key still reads as the account it guards.
  defp login_pair(downcased_email, ip),
    do: "#{downcased_email}|#{Helpers.source_key(ip)}"

  defp check_auth_ip_bucket(ip) when is_binary(ip) and ip != "" do
    Helpers.check_window("login_ip:#{Helpers.source_key(ip)}", 50, 1_800_000,
      operation: "authentication (ip)",
      identifier: ip,
      log: false
    )
  end

  defp check_auth_ip_bucket(_invalid_ip), do: :ok
end
