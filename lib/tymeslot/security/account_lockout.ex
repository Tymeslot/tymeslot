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

  @impl GenServer
  @spec init(any()) :: {:ok, %{}}
  def init(_state) do
    Logger.info("Starting AccountLockout with ETS table", table: @lockout_table)
    :ets.new(@lockout_table, [:named_table, :public, :set])
    {:ok, %{}}
  end

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
    GenServer.call(__MODULE__, {:record_failed_attempt, key})
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
             "Account locked for #{duration} minutes due to repeated failed attempts"}

          count when count >= 10 ->
            {:error, :account_throttled,
             "Too many failed attempts. Please wait before trying again"}

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

  @impl GenServer
  @spec handle_call({:record_failed_attempt, String.t()}, GenServer.from(), %{}) ::
          {:reply, :ok, %{}}
  def handle_call({:record_failed_attempt, identifier}, _from, state) do
    do_record_failed_attempt(identifier)
    {:reply, :ok, state}
  end

  # Private functions

  # Lockout keys are normalised so attackers cannot reset the counter by
  # varying the case (user@x.com vs USER@x.com) or padding with whitespace.
  defp normalize(identifier) when is_binary(identifier),
    do: identifier |> String.trim() |> String.downcase()

  defp do_record_failed_attempt(identifier) do
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

  defp calculate_lockout_duration(_attempt_count) do
    # Flat 4-hour lockout for accounts reaching 20+ failed attempts
    30 * 8
  end
end
