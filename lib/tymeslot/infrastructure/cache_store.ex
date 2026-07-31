defmodule Tymeslot.Infrastructure.CacheStore do
  @moduledoc """
  A reusable base for ETS-based caches.
  Provides standard lookup, compute, and cleanup logic.
  """

  require Logger

  @type pending_entry :: %{
          required(:waiters) => [GenServer.from()],
          required(:ref) => reference()
        }
  @type state :: %{required(:pending) => %{term() => pending_entry()}}

  defmacro __using__(opts) do
    quote do
      use GenServer
      alias Tymeslot.Infrastructure.CacheStore

      @table_name unquote(opts[:table_name])
      @default_ttl unquote(opts[:default_ttl] || :timer.minutes(5))
      @cleanup_interval unquote(opts[:cleanup_interval] || :timer.minutes(10))

      # Client API

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @doc """
      Get a value from cache or compute it if missing/expired.
      Coalesces concurrent requests for the same key to prevent cache stampedes.

      Pass `cache_errors: false` in `opts` to skip storing an `{:error, _}`
      result: the next call recomputes instead of replaying a stale failure
      for the rest of the TTL. Off by default so existing callers keep their
      current semantics.
      """
      def get_or_compute(key, fun, ttl \\ @default_ttl, opts \\ []) do
        case CacheStore.lookup(@table_name, key) do
          {:ok, value} ->
            value

          :miss ->
            # In test environment, compute directly to avoid ownership issues with background tasks.
            # This ensures that database connections and Mox expectations are preserved.
            if Application.get_env(:tymeslot, :environment) == :test and
                 not Application.get_env(:tymeslot, :force_cache_coalescing, false) do
              CacheStore.compute_and_store(@table_name, key, fun, ttl, opts)
            else
              # Use GenServer to coalesce concurrent computations
              GenServer.call(__MODULE__, {:compute_coalesced, key, fun, ttl, opts}, 90_000)
            end
        end
      end

      @doc """
      Invalidate a specific cache key.
      """
      def invalidate(key) do
        :ets.delete(@table_name, key)
      end

      @doc """
      Invalidate all cache entries matching a pattern.
      """
      def invalidate_pattern(pattern) do
        :ets.match_delete(@table_name, {pattern, :_, :_})
      end

      @doc """
      Clear all cache entries.
      """
      def clear_all do
        :ets.delete_all_objects(@table_name)
      end

      @doc """
      Manually insert a value into the cache.
      """
      def put(key, value, ttl \\ @default_ttl) do
        expiry = System.monotonic_time(:millisecond) + ttl
        :ets.insert(@table_name, {key, value, expiry})
        :ok
      end

      # Server Callbacks

      @impl GenServer
      def init(_opts) do
        CacheStore.init_cache(@table_name, @cleanup_interval)
      end

      @impl GenServer
      def handle_call({:compute_coalesced, key, fun, ttl, opts}, from, state) do
        CacheStore.handle_compute_coalesced(@table_name, key, fun, ttl, opts, from, state)
      end

      @impl GenServer
      def handle_info({:computation_done, key, value, ttl, opts}, state) do
        CacheStore.handle_computation_done(@table_name, key, value, ttl, opts, state)
      end

      @impl GenServer
      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        CacheStore.handle_task_down(state, ref)
      end

      @impl GenServer
      def handle_info(:cleanup, state) do
        CacheStore.cleanup_expired(@table_name)
        CacheStore.schedule_cleanup(@cleanup_interval)
        {:noreply, state}
      end

      @impl GenServer
      def handle_info(_msg, state) do
        {:noreply, state}
      end

      defoverridable init: 1, handle_info: 2, clear_all: 0
    end
  end

  # Helpers to reduce quote block size

  @doc false
  @spec init_cache(atom(), integer()) :: {:ok, state()}
  def init_cache(table_name, cleanup_interval) do
    :ets.new(table_name, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    schedule_cleanup(cleanup_interval)
    {:ok, %{pending: %{}}}
  end

  @doc false
  @spec handle_compute_coalesced(
          atom(),
          any(),
          (-> any()),
          integer(),
          keyword(),
          GenServer.from(),
          state()
        ) :: {:reply, any(), state()} | {:noreply, state()}
  def handle_compute_coalesced(table_name, key, fun, ttl, opts, from, state) do
    case lookup(table_name, key) do
      {:ok, value} ->
        {:reply, value, state}

      :miss ->
        case Map.get(state.pending, key) do
          nil ->
            parent = self()

            {:ok, pid} =
              Task.start(fn ->
                value =
                  try do
                    fun.()
                  catch
                    kind, reason ->
                      exit({kind, reason, __STACKTRACE__})
                  end

                send(parent, {:computation_done, key, value, ttl, opts})
              end)

            ref = Process.monitor(pid)
            new_state = put_in(state.pending[key], %{waiters: [from], ref: ref})
            {:noreply, new_state}

          %{waiters: waiters} ->
            new_state = put_in(state.pending[key].waiters, [from | waiters])
            {:noreply, new_state}
        end
    end
  end

  @doc false
  @spec handle_computation_done(atom(), any(), any(), integer(), keyword(), state()) ::
          {:noreply, state()}
  def handle_computation_done(table_name, key, value, ttl, opts, state) do
    case Map.pop(state.pending, key) do
      {nil, _value} ->
        {:noreply, state}

      {%{waiters: waiters, ref: ref}, pending} ->
        Process.demonitor(ref, [:flush])

        maybe_store(table_name, key, value, ttl, opts)

        Enum.each(waiters, fn waiter ->
          GenServer.reply(waiter, value)
        end)

        {:noreply, %{state | pending: pending}}
    end
  end

  @doc false
  @spec handle_task_down(state(), reference()) :: {:noreply, state()}
  def handle_task_down(state, ref) do
    entry = Enum.find(state.pending, fn {_key, val} -> val.ref == ref end)

    case entry do
      {key, %{waiters: waiters}} ->
        Enum.each(waiters, fn waiter ->
          GenServer.reply(waiter, {:error, :computation_failed})
        end)

        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      _other ->
        {:noreply, state}
    end
  end

  @doc false
  @spec lookup(atom(), any()) :: {:ok, any()} | :miss
  def lookup(table_name, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table_name, key) do
      [{^key, value, expiry}] when expiry > now ->
        {:ok, value}

      _other ->
        :miss
    end
  end

  @doc false
  @spec compute_and_store(atom(), any(), (-> any()), integer(), keyword()) :: any()
  def compute_and_store(table_name, key, fun, ttl, opts \\ []) do
    result =
      try do
        {:ok, fun.()}
      rescue
        exception ->
          if Application.get_env(:tymeslot, :environment) == :test do
            reraise exception, __STACKTRACE__
          end

          {:raised, exception, __STACKTRACE__}
      catch
        kind, reason ->
          if Application.get_env(:tymeslot, :environment) == :test do
            :erlang.raise(kind, reason, __STACKTRACE__)
          end

          {:caught, kind, reason, __STACKTRACE__}
      end

    case result do
      {:ok, value} ->
        maybe_store(table_name, key, value, ttl, opts)
        value

      {:raised, exception, stacktrace} ->
        Logger.warning("Cache computation raised an exception",
          table: table_name,
          key: inspect(key),
          exception: Exception.message(exception)
        )

        Logger.debug("Cache computation stacktrace",
          stacktrace: Exception.format_stacktrace(stacktrace)
        )

        {:error, :computation_failed}

      {:caught, kind, reason, stacktrace} ->
        Logger.warning("Cache computation failed",
          table: table_name,
          key: inspect(key),
          kind: kind,
          reason: inspect(reason)
        )

        Logger.debug("Cache computation stacktrace",
          stacktrace: Exception.format_stacktrace(stacktrace)
        )

        {:error, :computation_failed}
    end
  end

  @doc false
  @spec cleanup_expired(atom()) :: integer()
  def cleanup_expired(table_name) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(table_name, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])
  end

  @doc false
  @spec schedule_cleanup(integer()) :: reference()
  def schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  # `cache_errors: false` (see `get_or_compute/4`) skips the ETS insert for an
  # `{:error, _}` result so a transient failure is retried on the very next
  # call instead of being replayed for the rest of the TTL.
  defp maybe_store(table_name, key, value, ttl, opts) do
    if cacheable?(value, opts) do
      expiry = System.monotonic_time(:millisecond) + ttl
      :ets.insert(table_name, {key, value, expiry})
    end
  end

  defp cacheable?({:error, _reason}, opts), do: Keyword.get(opts, :cache_errors, true)
  defp cacheable?(_value, _opts), do: true
end
