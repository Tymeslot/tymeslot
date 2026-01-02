defmodule Tymeslot.Integrations.Calendar.Auth.TokenRefreshLock do
  @moduledoc """
  Provides a simple locking mechanism to ensure only one token refresh operation
  happens at a time for a given calendar integration.

  Uses a supervised GenServer to own a :protected ETS table and monitor holders.
  """

  use GenServer
  require Logger

  @table :token_refresh_locks
  @lock_timeout_ms 90_000

  # Client API

  @doc """
  Starts the lock manager.
  """
  @spec start_link(list()) :: {:ok, pid()} | {:error, any()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initializes the lock table. Should be called during application startup.
  """
  @spec init() :: :ok
  def init do
    # For backward compatibility with the old init() API if needed,
    # though it should now be started via supervisor.
    case GenServer.whereis(__MODULE__) do
      nil ->
        # If not started, we can't really "init" just the table if we want :protected ownership.
        # The application should start this in its supervisor.
        Logger.warning("TokenRefreshLock.init() called but process not started via supervisor")
        :ok

      _pid ->
        :ok
    end
  end

  @doc """
  Executes the given function with a lock for the specified integration.
  Returns the result of the function, or `{:error, :refresh_in_progress}` if the lock
  could not be acquired.
  """
  @spec with_lock(atom(), integer(), function()) :: any()
  def with_lock(provider, integration_id, fun) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :lock_manager_not_started}

      _pid ->
        lock_key = {provider, integration_id}

        case GenServer.call(__MODULE__, {:acquire, lock_key}) do
          :ok ->
            try do
              fun.()
            after
              GenServer.cast(__MODULE__, {:release, lock_key, self()})
            end

          {:error, :refresh_in_progress} ->
            Logger.debug("Token refresh already in progress for #{provider} integration #{integration_id}")
            {:error, :refresh_in_progress}
        end
    end
  end

  # Test-only helpers
  if Mix.env() == :test do
    @spec put_lock(atom() | String.t(), integer(), integer(), pid()) :: :ok
    def put_lock(provider, integration_id, timestamp, pid) do
      provider_atom =
        case provider do
          p when is_binary(p) -> String.to_existing_atom(p)
          p when is_atom(p) -> p
        end

      GenServer.call(__MODULE__, {:test_put_lock, {provider_atom, integration_id}, timestamp, pid})
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create the table as :protected - only the GenServer can write to it.
    :ets.new(@table, [:set, :protected, :named_table, {:read_concurrency, true}])
    {:ok, %{monitors: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:acquire, key}, {from_pid, _tag}, state) do
    ensure_table_exists()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, timestamp, _holder_pid}] when now - timestamp <= @lock_timeout_ms ->
        {:reply, {:error, :refresh_in_progress}, state}

      [{^key, _timestamp, old_pid}] ->
        # Lock expired. Clean up old monitor before overwriting.
        state = cleanup_monitor(state, key, old_pid)

        ref = Process.monitor(from_pid)
        :ets.insert(@table, {key, now, from_pid})

        new_state =
          state
          |> put_in([:monitors, ref], {key, from_pid})
          |> put_in([:refs, {key, from_pid}], ref)

        {:reply, :ok, new_state}

      _ ->
        # No lock.
        ref = Process.monitor(from_pid)
        :ets.insert(@table, {key, now, from_pid})

        new_state =
          state
          |> put_in([:monitors, ref], {key, from_pid})
          |> put_in([:refs, {key, from_pid}], ref)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:test_put_lock, key, timestamp, pid}, _from, state) do
    ensure_table_exists()
    # In tests, we might overwrite. Clean up monitor if we're simulating a real holder.
    state =
      case :ets.lookup(@table, key) do
        [{^key, _, old_pid}] -> cleanup_monitor(state, key, old_pid)
        _ -> state
      end

    :ets.insert(@table, {key, timestamp, pid})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:release, key, pid}, state) do
    ensure_table_exists()

    case :ets.lookup(@table, key) do
      [{^key, _timestamp, ^pid}] ->
        :ets.delete(@table, key)
        {:noreply, cleanup_monitor(state, key, pid)}

      _ ->
        # Not the holder or no lock
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    ensure_table_exists()

    case Map.pop(state.monitors, ref) do
      {{key, ^pid}, next_monitors} ->
        # If the process that died was still holding the lock, release it.
        case :ets.lookup(@table, key) do
          [{^key, _timestamp, ^pid}] ->
            :ets.delete(@table, key)
            Logger.debug("Released lock for #{inspect(key)} because process #{inspect(pid)} died")

          _ ->
            :ok
        end

        next_refs = Map.delete(state.refs, {key, pid})
        {:noreply, %{state | monitors: next_monitors, refs: next_refs}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # Private helper to ensure the ETS table exists.
  # This is mainly for robustness and to support tests that explicitly delete the table.
  defp ensure_table_exists do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :protected, :named_table, {:read_concurrency, true}])
    end
  end

  defp cleanup_monitor(state, key, pid) do
    case Map.pop(state.refs, {key, pid}) do
      {nil, _} ->
        state

      {ref, next_refs} ->
        Process.demonitor(ref, [:flush])
        next_monitors = Map.delete(state.monitors, ref)
        %{state | monitors: next_monitors, refs: next_refs}
    end
  end
end
