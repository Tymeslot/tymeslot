defmodule Tymeslot.Security.AccountLockout do
  @moduledoc """
  Account lockout mechanism to prevent brute force attacks.

  Uses ETS for fast, in-memory tracking of failed attempts. The ETS table is owned
  by `Tymeslot.Security.AccountLockout.TableOwner` and survives this module's
  caller crashing — but does NOT survive a BEAM restart, node shutdown, or deploy.

  ## One tier, deliberately

  There is a single defence here: once an identifier accumulates ten failures
  inside the last hour, further attempts are throttled until old failures age
  out of that window. There is no second, harder tier, and adding one would be
  a mistake for two reasons:

  - `RateLimiter.Auth.check_auth/2` consults `check_lockout_status/1` *before*
    password verification, and that check is read-only. Once the throttle
    threshold is reached the login path short-circuits and stops recording
    failures, so the counter freezes at the threshold and a higher one is
    unreachable by sequential brute force.
  - Making it reachable would mean recording attempts the pre-check already
    rejected. The counter is keyed on the email address alone, in a node-local
    table, so that hands anyone who knows a victim's address a way to lock
    that account out at will. A throttle that re-opens hourly degrades an
    attacker; a hard lock triggered the same way degrades the account owner.

  A previous revision defined a 20-failure tier returning `:account_locked`
  with a flat four-hour duration. It was removed rather than repaired: it never
  fired under sequential brute force, and the only ways to make it fire are the
  denial-of-service above.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.AccountLockout.TableOwner
  alias Tymeslot.Security.SecurityLogger

  require Logger

  @lockout_table :account_lockout_table

  # Failures inside @recent_window_seconds needed to throttle an identifier.
  @throttle_threshold 10
  @recent_window_seconds 3600

  @doc """
  Checks and records an authentication attempt.

  Returns `:ok` if allowed, `{:error, :account_throttled, message}` once the
  identifier has crossed the throttle threshold.
  """
  @spec check_and_record_attempt(String.t(), boolean()) ::
          :ok | {:error, :account_throttled, String.t()}
  def check_and_record_attempt(identifier, true) do
    clear_failed_attempts(identifier)
    :ok
  end

  def check_and_record_attempt(identifier, false) do
    key = normalize(identifier)
    do_record_failed_attempt(key)
    check_lockout_status(key)
  end

  @doc """
  Checks whether an account is currently throttled, without recording an
  attempt.
  """
  @spec check_lockout_status(String.t()) :: :ok | {:error, :account_throttled, String.t()}
  def check_lockout_status(identifier) do
    key = normalize(identifier)

    case :ets.lookup(@lockout_table, key) do
      [{^key, attempts}] ->
        if recent_attempt_count(attempts) >= @throttle_threshold do
          {:error, :account_throttled,
           dgettext("auth", "Too many failed attempts. Please wait before trying again")}
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Manually clear failed attempts for an identifier (e.g., after successful password reset).
  """
  @spec clear_failed_attempts(String.t()) :: :ok
  def clear_failed_attempts(identifier) do
    :ets.delete(@lockout_table, normalize(identifier))
    :ok
  end

  @doc """
  Clear every recorded failed attempt.

  Test-only. The lockout table is VM-global and outlives the process that wrote
  to it, so a test asserting an absolute attempt count needs the table reset
  first; `Tymeslot.DataCase.reset_stateful_components/1` calls this for sync
  modules, alongside the equivalent rate-limiter reset.
  """
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(@lockout_table)
    :ok
  end

  @doc """
  Get current failed attempt count for an identifier.
  """
  @spec get_failed_attempt_count(String.t()) :: integer()
  def get_failed_attempt_count(identifier) do
    key = normalize(identifier)

    case :ets.lookup(@lockout_table, key) do
      [{^key, attempts}] ->
        now = System.system_time(:second)
        # Count attempts from last 24 hours
        recent_attempts =
          Enum.filter(attempts, fn timestamp ->
            now - timestamp < 86_400
          end)

        length(recent_attempts)

      [] ->
        0
    end
  end

  # Private functions

  defp recent_attempt_count(attempts) do
    now = System.system_time(:second)
    Enum.count(attempts, fn timestamp -> now - timestamp < @recent_window_seconds end)
  end

  # Lockout keys are normalised so attackers cannot reset the counter by
  # varying the case (user@x.com vs USER@x.com) or padding with whitespace.
  defp normalize(identifier) when is_binary(identifier),
    do: identifier |> String.trim() |> String.downcase()

  # Writes go through the TableOwner GenServer to serialise the read-modify-write
  # cycle — a `:public` ETS table alone cannot prevent two concurrent callers
  # from both reading the same attempt list and clobbering each other's insert.
  defp do_record_failed_attempt(identifier) do
    # This fires on *every* failed attempt, so it is the highest-volume line in
    # the auth path under a credential-stuffing run. The identifier is the
    # normalised email address; it is masked here rather than left to the
    # global metadata filter.
    masked = SecurityLogger.mask_email(identifier)

    case TableOwner.record_attempt(identifier) do
      1 ->
        Logger.info("First failed attempt recorded", identifier_masked: masked)

      total ->
        Logger.info("Failed attempt recorded",
          identifier_masked: masked,
          total_attempts: total
        )
    end
  end
end
