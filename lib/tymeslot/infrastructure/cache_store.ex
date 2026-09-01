defmodule Tymeslot.Infrastructure.CacheStore do
  @moduledoc """
  A reusable base for ETS-based caches.
  Provides standard lookup, compute, and cleanup logic.

  ## How a miss is computed

  Concurrent misses on the same key are coalesced so the expensive work
  happens once. The cache GenServer arbitrates that, but it never runs the
  computation itself: the first caller to miss is told to *lead* and runs
  `fun` in its own process, publishing the result to the cache when it is
  done; callers that arrive while it is in flight block until then and are
  handed the same value.

  Running `fun` in the caller rather than in a cache-owned worker is what
  makes the arrangement environment-independent. A computation that queries
  the database or meets a `Mox` expectation keeps the caller's sandbox
  connection and its mock allowances, neither of which a separate process
  gets for free — which is why this path used to be bypassed under test,
  leaving the coalescing that ships exercised by almost nothing.
  """

  require Logger

  @typedoc """
  One in-flight computation: the monitor on the process leading it, and the
  callers blocked on its result. The leader is not among the waiters — it
  returns its own value directly rather than through a `GenServer` reply.
  """
  @type pending_entry :: %{
          required(:waiters) => [GenServer.from()],
          required(:ref) => reference()
        }
  @type state :: %{required(:pending) => %{term() => pending_entry()}}

  # A waiter stays blocked in `GenServer.call/3` for as long as the leader's
  # computation takes, so this bounds the slowest cached computation (a cold
  # CalDAV round trip), not the arbitration call itself.
  @compute_timeout :timer.seconds(90)

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

      `fun` always runs in the calling process, whichever caller ends up
      leading the computation; the cache GenServer only decides who that is.
      See the `Tymeslot.Infrastructure.CacheStore` moduledoc.

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
            CacheStore.compute_coalesced(__MODULE__, @table_name, key, fun, ttl, opts)
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
      def handle_call({:join_computation, key}, from, state) do
        CacheStore.handle_join_computation(@table_name, key, from, state)
      end

      @impl GenServer
      def handle_info({:computation_done, key, value}, state) do
        CacheStore.handle_computation_done(key, value, state)
      end

      @impl GenServer
      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        CacheStore.handle_leader_down(state, ref)
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
  @spec compute_coalesced(module(), atom(), any(), (-> any()), integer(), keyword()) :: any()
  def compute_coalesced(server, table_name, key, fun, ttl, opts) do
    case GenServer.call(server, {:join_computation, key}, @compute_timeout) do
      :lead -> lead_computation(server, table_name, key, fun, ttl, opts)
      {:value, value} -> value
    end
  end

  # Runs in the leading caller, not in the cache. The result is stored before
  # the cache is told about it, which keeps `get_or_compute/4`'s postcondition:
  # once it returns, the value is already in ETS, so a call that immediately
  # follows is a hit rather than a second computation.
  defp lead_computation(server, table_name, key, fun, ttl, opts) do
    value = compute_and_store(table_name, key, fun, ttl, opts)
    send(server, {:computation_done, key, value})
    value
  end

  @doc false
  @spec handle_join_computation(atom(), any(), GenServer.from(), state()) ::
          {:reply, :lead | {:value, any()}, state()} | {:noreply, state()}
  def handle_join_computation(table_name, key, from, state) do
    case lookup(table_name, key) do
      {:ok, value} ->
        {:reply, {:value, value}, state}

      :miss ->
        case Map.get(state.pending, key) do
          nil ->
            {:reply, :lead, put_in(state.pending[key], %{waiters: [], ref: monitor_caller(from)})}

          %{waiters: waiters} ->
            {:noreply, put_in(state.pending[key].waiters, [from | waiters])}
        end
    end
  end

  @doc false
  @spec handle_computation_done(any(), any(), state()) :: {:noreply, state()}
  def handle_computation_done(key, value, state) do
    case Map.pop(state.pending, key) do
      {nil, _pending} ->
        {:noreply, state}

      {%{waiters: waiters, ref: ref}, pending} ->
        Process.demonitor(ref, [:flush])

        Enum.each(waiters, fn waiter ->
          GenServer.reply(waiter, {:value, value})
        end)

        {:noreply, %{state | pending: pending}}
    end
  end

  @doc false
  @spec handle_leader_down(state(), reference()) :: {:noreply, state()}
  def handle_leader_down(state, ref) do
    case Enum.find(state.pending, fn {_key, entry} -> entry.ref == ref end) do
      {key, %{waiters: []}} ->
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      {key, %{waiters: waiters}} ->
        # The leader is a caller like any other, so it can go away for reasons
        # that say nothing about the result — a visitor closing the booking
        # page mid-fetch. Promote the longest-waiting caller rather than
        # failing everyone who is still interested. A successor that is itself
        # already dead brings its own `:DOWN` straight back here, so the
        # promotion walks down the queue until someone alive takes it.
        {successor, rest} = List.pop_at(waiters, -1)
        GenServer.reply(successor, :lead)
        entry = %{waiters: rest, ref: monitor_caller(successor)}
        {:noreply, put_in(state.pending[key], entry)}

      nil ->
        {:noreply, state}
    end
  end

  defp monitor_caller({pid, _tag}), do: Process.monitor(pid)

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
  # A failing computation resolves to `{:error, :computation_failed}` in every
  # environment. It used to re-raise under test, which meant the logging and
  # the failure value the callers actually receive in production were reached
  # by no test at all; the warning below carries the exception message, so a
  # test whose cached computation blows up still says so in the log.
  @spec compute_and_store(atom(), any(), (-> any()), integer(), keyword()) :: any()
  def compute_and_store(table_name, key, fun, ttl, opts \\ []) do
    result =
      try do
        {:ok, fun.()}
      rescue
        exception ->
          {:raised, exception, __STACKTRACE__}
      catch
        kind, reason ->
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
