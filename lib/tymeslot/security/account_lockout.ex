defmodule Tymeslot.Security.AccountLockout do
  @moduledoc """
  Account lockout mechanism to prevent brute force attacks.

  Implements progressive lockout with increasing delays for repeated failed attempts.
  Uses ETS for fast, in-memory tracking of failed attempts.
  """

  use GenServer
  require Logger

  @lockout_table :account_lockout_table

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec init(any()) :: {:ok, map()}
  def init(_) do
    Logger.info("Starting AccountLockout with ETS table", table: @lockout_table)
    :ets.new(@lockout_table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @doc """
  Checks and records authentication attempt.
  Returns :ok if allowed, {:error, reason, message} if locked/throttled.
  """
  @spec check_and_record_attempt(String.t(), boolean()) :: :ok | {:error, atom(), String.t()}
  def check_and_record_attempt(identifier, success) do
    case success do
      true ->
        clear_failed_attempts(identifier)
        :ok

      false ->
        record_failed_attempt(identifier)
        check_lockout_status(identifier)
    end
  end

  @doc """
  Checks if an account is currently locked without recording an attempt.
  """
  @spec check_lockout_status(String.t()) :: :ok | {:error, atom(), String.t()}
  def check_lockout_status(identifier) do
    case :ets.lookup(@lockout_table, identifier) do
      [{^identifier, attempts}] ->
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
             "Account locked for #{duration} minutes due to repeated failed attempts"}

          count when count >= 10 ->
            {:error, :account_throttled,
             "Too many failed attempts. Please wait before trying again"}

          _ ->
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
    :ets.delete(@lockout_table, identifier)
    :ok
  end

  @doc """
  Get current failed attempt count for an identifier.
  """
  @spec get_failed_attempt_count(String.t()) :: integer()
  def get_failed_attempt_count(identifier) do
    case :ets.lookup(@lockout_table, identifier) do
      [{^identifier, attempts}] ->
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

  defp record_failed_attempt(identifier) do
    now = System.system_time(:second)

    case :ets.lookup(@lockout_table, identifier) do
      [] ->
        :ets.insert(@lockout_table, {identifier, [now]})
        Logger.info("First failed attempt recorded", identifier: identifier)

      [{^identifier, attempts}] ->
        # Keep only attempts from last 24 hours
        recent_attempts =
          Enum.filter(attempts, fn timestamp ->
            now - timestamp < 86_400
          end)

        updated_attempts = [now | recent_attempts]
        :ets.insert(@lockout_table, {identifier, updated_attempts})

        Logger.info("Failed attempt recorded",
          identifier: identifier,
          total_attempts: length(updated_attempts)
        )
    end
  end

  defp calculate_lockout_duration(attempt_count) do
    base_minutes = 30
    # Cap at 8x for maximum of 4 hours
    multiplier = min(attempt_count - 8, 8)
    base_minutes * multiplier
  end
end
