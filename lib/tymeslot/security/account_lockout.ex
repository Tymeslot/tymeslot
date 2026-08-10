defmodule Tymeslot.Security.AccountLockout do
  @moduledoc """
  Account lockout mechanism to prevent brute force attacks.

  Implements progressive lockout with increasing delays for repeated failed attempts.
  Uses ETS for fast, in-memory tracking of failed attempts. The ETS table is owned
  by `Tymeslot.Security.AccountLockout.TableOwner` and survives this module's
  caller crashing — but does NOT survive a BEAM restart, node shutdown, or deploy.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.AccountLockout.TableOwner

  require Logger

  @lockout_table :account_lockout_table

  @doc """
  Checks and records authentication attempt.
  Returns :ok if allowed, {:error, reason, message} if locked/throttled.
  """
  @spec check_and_record_attempt(String.t(), boolean()) :: :ok | {:error, atom(), String.t()}
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
  Checks if an account is currently locked without recording an attempt.
  """
  @spec check_lockout_status(String.t()) :: :ok | {:error, atom(), String.t()}
  def check_lockout_status(identifier) do
    key = normalize(identifier)

    case :ets.lookup(@lockout_table, key) do
      [{^key, attempts}] ->
        now = System.system_time(:second)

        # Filter attempts from last hour for lockout calculation
        recent_attempts =
          Enum.filter(attempts, fn timestamp ->
            now - timestamp < 3600
          end)

        case length(recent_attempts) do
          count when count >= 20 ->
            duration = calculate_lockout_duration(count)

            {:error, :account_locked,
             dgettext(
               "auth",
               "Account locked for %{duration} minutes due to repeated failed attempts",
               duration: duration
             )}

          count when count >= 10 ->
            {:error, :account_throttled,
             dgettext("auth", "Too many failed attempts. Please wait before trying again")}

          _other ->
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

  # Lockout keys are normalised so attackers cannot reset the counter by
  # varying the case (user@x.com vs USER@x.com) or padding with whitespace.
  defp normalize(identifier) when is_binary(identifier),
    do: identifier |> String.trim() |> String.downcase()

  # Writes go through the TableOwner GenServer to serialise the read-modify-write
  # cycle — a `:public` ETS table alone cannot prevent two concurrent callers
  # from both reading the same attempt list and clobbering each other's insert.
  defp do_record_failed_attempt(identifier) do
    case TableOwner.record_attempt(identifier) do
      1 ->
        Logger.info("First failed attempt recorded", identifier: identifier)

      total ->
        Logger.info("Failed attempt recorded",
          identifier: identifier,
          total_attempts: total
        )
    end
  end

  defp calculate_lockout_duration(_attempt_count) do
    # Flat 4-hour lockout for accounts reaching 20+ failed attempts
    30 * 8
  end
end
