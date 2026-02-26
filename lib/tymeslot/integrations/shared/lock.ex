defmodule Tymeslot.Integrations.Shared.Lock do
  @moduledoc """
  Provides a simple locking mechanism for integration operations.
  Uses a supervised GenServer to own a :protected ETS table and monitor holders.
  """

  use GenServer
  require Logger

  @table :integration_operation_locks
  @default_lock_timeout_ms 90_000
  @retry_interval_ms 200

  # Client API

  @doc """
  Starts the lock manager.
  """
  @spec start_link(list()) :: {:ok, pid()} | {:error, any()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes the given function with a lock for the specified key.

  Options:
    - :mode - :non_blocking (default) or :blocking
    - :timeout - max time to wait in :blocking mode (default 30_000ms)
  """
  @spec with_lock(atom(), integer(), (-> any())) :: any()
  @spec with_lock(any(), (-> any()), keyword()) :: any()
  def with_lock(key, fun, opts \\ [])

  # Backward compatibility for calendar integrations: with_lock(provider, integration_id, fun)
  def with_lock(provider, integration_id, fun)
      when is_atom(provider) and is_integer(integration_id) and is_function(fun) do
    do_with_lock({provider, integration_id}, fun, [])
  end

  def with_lock(key, fun, opts) when is_function(fun) and is_list(opts) do
    do_with_lock(key, fun, opts)
  end

  defp do_with_lock(key, fun, opts) do
    mode = Keyword.get(opts, :mode, :non_blocking)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case mode do
      :blocking ->
        do_with_lock_blocking(key, fun, timeout)

      :non_blocking ->
        do_with_lock_non_blocking(key, fun)
    end
  end

  defp do_with_lock_non_blocking(key, fun) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :lock_manager_not_started}

      _manager_pid ->
        case GenServer.call(__MODULE__, {:acquire, key}) do
          :ok ->
            try do
              fun.()
            after
              GenServer.cast(__MODULE__, {:release, key, self()})
            end

          {:error, :refresh_in_progress} ->
            {:error, :refresh_in_progress}
        end
    end
  end

  defp do_with_lock_blocking(key, fun, timeout, start_time \\ nil) do
    start_time = start_time || System.monotonic_time(:millisecond)
    now = System.monotonic_time(:millisecond)

    if now - start_time > timeout do
      {:error, :lock_timeout}
    else
      case do_with_lock_non_blocking(key, fun) do
        {:error, :refresh_in_progress} ->
          Process.sleep(@retry_interval_ms)
          do_with_lock_blocking(key, fun, timeout, start_time)

        result ->
          result
      end
    end
  end

  # Test-only helpers
  @doc false
  @spec put_lock(any(), integer(), pid()) :: :ok
  def put_lock(key, timestamp, pid) do
    GenServer.call(__MODULE__, {:test_put_lock, key, timestamp, pid})
  end

  defp get_lock_timeout(key) do
    config = Application.get_env(:tymeslot, :integration_locks, [])

    # Check for specific provider timeout first
    provider_timeout =
      case key do
        {provider, _id} when is_atom(provider) -> Keyword.get(config, provider)
        provider when is_atom(provider) -> Keyword.get(config, provider)
        _unknown_key -> nil
      end

    provider_timeout || Keyword.get(config, :default_timeout, @default_lock_timeout_ms)
  end

  # Server Callbacks

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, {:read_concurrency, true}])
    {:ok, %{monitors: %{}, refs: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, key}, {from_pid, _tag}, state) do
    ensure_table_exists()
    now = System.monotonic_time(:millisecond)
    lock_timeout_ms = get_lock_timeout(key)

    case :ets.lookup(@table, key) do
      [{^key, timestamp, _holder_pid}] when now - timestamp <= lock_timeout_ms ->
        :telemetry.execute([:tymeslot, :lock, :acquire, :timeout], %{duration: 0}, %{
          key: key,
          reason: :refresh_in_progress
        })

        {:reply, {:error, :refresh_in_progress}, state}

      [{^key, _timestamp, old_pid}] ->
        state = cleanup_monitor(state, key, old_pid)
        ref = Process.monitor(from_pid)
        :ets.insert(@table, {key, now, from_pid})

        new_state =
          state
          |> put_in([:monitors, ref], {key, from_pid})
          |> put_in([:refs, {key, from_pid}], ref)

        :telemetry.execute([:tymeslot, :lock, :acquire, :success], %{duration: 0}, %{
          key: key,
          preempted: true
        })

        {:reply, :ok, new_state}

      _no_existing_lock ->
        ref = Process.monitor(from_pid)
        :ets.insert(@table, {key, now, from_pid})

        new_state =
          state
          |> put_in([:monitors, ref], {key, from_pid})
          |> put_in([:refs, {key, from_pid}], ref)

        :telemetry.execute([:tymeslot, :lock, :acquire, :success], %{duration: 0}, %{
          key: key,
          preempted: false
        })

        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_call({:test_put_lock, key, timestamp, pid}, _from, state) do
    ensure_table_exists()

    state =
      case :ets.lookup(@table, key) do
        [{^key, _timestamp, old_pid}] -> cleanup_monitor(state, key, old_pid)
        [] -> state
      end

    :ets.insert(@table, {key, timestamp, pid})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:release, key, pid}, state) do
    ensure_table_exists()

    case :ets.lookup(@table, key) do
      [{^key, _timestamp, ^pid}] ->
        :ets.delete(@table, key)
        :telemetry.execute([:tymeslot, :lock, :release], %{}, %{key: key})
        {:noreply, cleanup_monitor(state, key, pid)}

      _different_holder ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    ensure_table_exists()

    case Map.pop(state.monitors, ref) do
      {{key, ^pid}, next_monitors} ->
        case :ets.lookup(@table, key) do
          [{^key, _timestamp, ^pid}] ->
            :ets.delete(@table, key)

            Logger.debug("Released lock because process died",
              key: inspect(key),
              pid: inspect(pid)
            )

          _different_holder ->
            :ok
        end

        next_refs = Map.delete(state.refs, {key, pid})
        {:noreply, %{state | monitors: next_monitors, refs: next_refs}}

      {nil, _next_monitors} ->
        {:noreply, state}
    end
  end

  defp ensure_table_exists do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :protected, :named_table, {:read_concurrency, true}])
    end
  end

  defp cleanup_monitor(state, key, pid) do
    case Map.pop(state.refs, {key, pid}) do
      {nil, _next_refs} ->
        state

      {ref, next_refs} ->
        Process.demonitor(ref, [:flush])
        next_monitors = Map.delete(state.monitors, ref)
        %{state | monitors: next_monitors, refs: next_refs}
    end
  end
end
