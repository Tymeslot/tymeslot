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

  ## Invalidation

  A computation reads the world as it was when it started, so one still in
  flight when its key is invalidated holds a value that is already stale.
  Invalidation, joining a computation and storing its result are therefore
  all arbitrated by the cache GenServer: invalidating a key detaches its
  in-flight computation, whose result then reaches only the callers that were
  already waiting on it and is never stored, and the next caller to miss
  leads a fresh computation instead of joining the superseded one.
  """

  require Logger

  @typedoc """
  One in-flight computation: the token its leader was handed, the monitor on
  the process leading it, and the callers blocked on its result. The leader
  is not among the waiters: it returns its own value directly rather than
  through a `GenServer` reply.
  """
  @type pending_entry :: %{
          required(:token) => reference(),
          required(:waiters) => [GenServer.from()],
          required(:ref) => reference()
        }

  @typedoc "What one invalidation drops: a key, a key pattern, or everything."
  @type scope :: {:key, any()} | {:pattern, any()} | :all

  @typedoc """
  `pending` holds the current computation per key, the only ones whose result
  may be stored. `superseded` holds, by token, computations whose key was
  invalidated while they ran: their waiters still get the result, but
  nothing is stored and no new caller joins them.
  """
  @type state :: %{
          required(:pending) => %{term() => pending_entry()},
          required(:superseded) => %{reference() => {term(), pending_entry()}}
        }

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
      Invalidate a specific cache key, including a computation for it that
      is still in flight: its result is not stored.
      """
      def invalidate(key) do
        CacheStore.invalidate(__MODULE__, {:key, key})
      end

      @doc """
      Invalidate all cache entries matching a pattern, and any in-flight
      computation whose key matches it.
      """
      def invalidate_pattern(pattern) do
        CacheStore.invalidate(__MODULE__, {:pattern, pattern})
      end

      @doc """
      Clear all cache entries, and detach every in-flight computation.
      """
      def clear_all do
        CacheStore.invalidate(__MODULE__, :all)
      end

      @doc """
      Invalidate several keys or patterns as one step: no computation can
      start between them, so none can read an entry that one scope drops
      while another has already been dropped.
      """
      def invalidate_together(scopes) when is_list(scopes) do
        CacheStore.invalidate(__MODULE__, scopes)
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

      def handle_call({:computation_done, key, token, value, store}, _from, state) do
        CacheStore.handle_computation_done(@table_name, key, token, value, store, state)
      end

      def handle_call({:invalidate, scope}, _from, state) do
        CacheStore.handle_invalidate(@table_name, scope, state)
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
    {:ok, %{pending: %{}, superseded: %{}}}
  end

  @doc false
  @spec compute_coalesced(module(), atom(), any(), (-> any()), integer(), keyword()) :: any()
  def compute_coalesced(server, table_name, key, fun, ttl, opts) do
    case GenServer.call(server, {:join_computation, key}, @compute_timeout) do
      {:lead, token} -> lead_computation(server, table_name, key, token, fun, ttl, opts)
      {:value, value} -> value
    end
  end

  # Runs in the leading caller, not in the cache. The result is handed to the
  # cache synchronously, which stores it (unless the key was invalidated
  # meanwhile) before replying. That keeps `get_or_compute/4`'s postcondition:
  # once it returns, the value is already in ETS, so a call that immediately
  # follows is a hit rather than a second computation.
  defp lead_computation(server, table_name, key, token, fun, ttl, opts) do
    {value, store} =
      case compute(table_name, key, fun) do
        {:ok, value} -> {value, if(cacheable?(value, opts), do: {:store, ttl}, else: :skip)}
        # A failed computation is never stored, whatever `cache_errors` says.
        {:failed, value} -> {value, :skip}
      end

    :ok = GenServer.call(server, {:computation_done, key, token, value, store})
    value
  end

  @doc false
  @spec handle_join_computation(atom(), any(), GenServer.from(), state()) ::
          {:reply, {:lead, reference()} | {:value, any()}, state()} | {:noreply, state()}
  def handle_join_computation(table_name, key, from, state) do
    case lookup(table_name, key) do
      {:ok, value} ->
        {:reply, {:value, value}, state}

      :miss ->
        case Map.get(state.pending, key) do
          nil ->
            token = make_ref()
            entry = %{token: token, waiters: [], ref: monitor_caller(from)}
            {:reply, {:lead, token}, put_in(state.pending[key], entry)}

          %{waiters: waiters} ->
            {:noreply, put_in(state.pending[key].waiters, [from | waiters])}
        end
    end
  end

  @doc false
  @spec handle_computation_done(
          atom(),
          any(),
          reference(),
          any(),
          {:store, integer()} | :skip,
          state()
        ) :: {:reply, :ok, state()}
  def handle_computation_done(table_name, key, token, value, store, state) do
    {entry, state} =
      case state.pending do
        %{^key => %{token: ^token} = entry} ->
          maybe_store(table_name, key, value, store)
          {entry, %{state | pending: Map.delete(state.pending, key)}}

        _current ->
          # Superseded by an invalidation (or unknown, if the cache restarted
          # meanwhile): the value predates the invalidation, so it only goes
          # to the callers that asked before it.
          case Map.pop(state.superseded, token) do
            {{_key, entry}, superseded} -> {entry, %{state | superseded: superseded}}
            {nil, _superseded} -> {nil, state}
          end
      end

    reply_waiters(entry, value)
    {:reply, :ok, state}
  end

  defp reply_waiters(nil, _value), do: :ok

  defp reply_waiters(%{waiters: waiters, ref: ref}, value) do
    Process.demonitor(ref, [:flush])
    Enum.each(waiters, &GenServer.reply(&1, {:value, value}))
  end

  @doc false
  # The table belongs to the cache process, so while the process is down (a
  # restart in progress) there is nothing cached to invalidate. Callers
  # invalidate after committing a change and must not crash for it.
  @spec invalidate(GenServer.server(), scope() | [scope()]) :: true
  def invalidate(server, scope) do
    GenServer.call(server, {:invalidate, scope})
  catch
    :exit, {:noproc, _call} -> true
  end

  @doc false
  @spec handle_invalidate(atom(), scope() | [scope()], state()) :: {:reply, true, state()}
  def handle_invalidate(table_name, scopes, state) when is_list(scopes) do
    state = Enum.reduce(scopes, state, &detach(table_name, &1, &2))
    {:reply, true, state}
  end

  def handle_invalidate(table_name, scope, state) do
    {:reply, true, detach(table_name, scope, state)}
  end

  defp detach(table_name, scope, state) do
    # A table someone dropped from outside leaves nothing to delete; failing
    # here would take the cache process down with it.
    if :ets.whereis(table_name) != :undefined, do: delete_entries(table_name, scope)

    {detached, pending} =
      Map.split_with(state.pending, fn {key, _entry} -> in_scope?(scope, key) end)

    superseded =
      Enum.reduce(detached, state.superseded, fn {key, entry}, acc ->
        Map.put(acc, entry.token, {key, entry})
      end)

    %{state | pending: pending, superseded: superseded}
  end

  defp delete_entries(table_name, {:key, key}), do: :ets.delete(table_name, key)

  defp delete_entries(table_name, {:pattern, pattern}),
    do: :ets.match_delete(table_name, {pattern, :_, :_})

  defp delete_entries(table_name, :all), do: :ets.delete_all_objects(table_name)

  defp in_scope?({:key, target}, key), do: key === target
  defp in_scope?(:all, _key), do: true

  defp in_scope?({:pattern, pattern}, key) do
    match_spec = :ets.match_spec_compile([{{pattern}, [], [true]}])
    :ets.match_spec_run([{key}], match_spec) == [true]
  end

  @doc false
  @spec handle_leader_down(state(), reference()) :: {:noreply, state()}
  def handle_leader_down(state, ref) do
    pending_hit = Enum.find(state.pending, fn {_key, entry} -> entry.ref == ref end)
    superseded_hit = Enum.find(state.superseded, fn {_token, {_key, e}} -> e.ref == ref end)

    case {pending_hit, superseded_hit} do
      {{key, entry}, _none} ->
        {:noreply, %{state | pending: put_or_delete(state.pending, key, hand_over(entry))}}

      {nil, {token, {key, entry}}} ->
        successor = with %{} = next <- hand_over(entry), do: {key, next}
        {:noreply, %{state | superseded: put_or_delete(state.superseded, token, successor)}}

      {nil, nil} ->
        {:noreply, state}
    end
  end

  # The leader is a caller like any other, so it can go away for reasons that
  # say nothing about the result: a visitor closing the booking page
  # mid-fetch. Promote the longest-waiting caller rather than failing everyone
  # who is still interested; it keeps the computation's token, so a
  # superseded computation stays superseded. A successor that is itself
  # already dead brings its own `:DOWN` straight back here, so the promotion
  # walks down the queue until someone alive takes it.
  defp hand_over(%{waiters: []}), do: nil

  defp hand_over(%{token: token, waiters: waiters}) do
    {successor, rest} = List.pop_at(waiters, -1)
    GenServer.reply(successor, {:lead, token})
    %{token: token, waiters: rest, ref: monitor_caller(successor)}
  end

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

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
  #
  # Not recorded through `ErrorTracking.report_error/3`: modules `use` this one,
  # so anything it references becomes a compile-time dependency of each of
  # them, and ErrorTracking would pull its queries and the Repo in with it.
  # For the same reason the key and reason are rendered by `render/1` below
  # rather than `LogFormat.reason/1`.
  @spec compute(atom(), any(), (-> any())) ::
          {:ok, any()} | {:failed, {:error, :computation_failed}}
  def compute(table_name, key, fun) do
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
        {:ok, value}

      {:raised, exception, stacktrace} ->
        Logger.warning("Cache computation raised an exception",
          table: table_name,
          key: render(key),
          exception: exception |> Exception.message() |> redact()
        )

        Logger.debug("Cache computation stacktrace",
          stacktrace: Exception.format_stacktrace(stacktrace)
        )

        {:failed, {:error, :computation_failed}}

      {:caught, kind, reason, stacktrace} ->
        Logger.warning("Cache computation failed",
          table: table_name,
          key: render(key),
          kind: kind,
          reason: render(reason)
        )

        Logger.debug("Cache computation stacktrace",
          stacktrace: Exception.format_stacktrace(stacktrace)
        )

        {:failed, {:error, :computation_failed}}
    end
  end

  # A bounded `inspect/2` standing in for `LogFormat.reason/1`, which would
  # put LogFormat and the redaction modules behind it on the compile-time
  # graph of every cache (see `compute/3`). Cache keys are built from
  # ids and dates, not credentials; a thrown or exited reason is the one term
  # here that is not, so the rendering is capped and then scrubbed of what
  # shows up in text (bearer headers, query-string tokens, quoted secrets).
  defp render(term), do: term |> inspect(limit: 20, printable_limit: 256) |> redact()

  # `Logging.Redactor.redact/1`, called through a module atom returned at
  # runtime rather than an alias: xref records an alias as a reference, and
  # every module that `use`s this one would then count the redactor on its
  # compile-connected graph. The regex-only redactor is the one piece of log
  # scrubbing that needs nothing else from the application.
  defp redact(text), do: redactor().redact(text)
  defp redactor, do: :"Elixir.Tymeslot.Infrastructure.Logging.Redactor"

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

  defp maybe_store(_table_name, _key, _value, :skip), do: :ok

  defp maybe_store(table_name, key, value, {:store, ttl}) do
    expiry = System.monotonic_time(:millisecond) + ttl
    :ets.insert(table_name, {key, value, expiry})
  end

  # `cache_errors: false` (see `get_or_compute/4`) skips the ETS insert for an
  # `{:error, _}` result so a transient failure is retried on the very next
  # call instead of being replayed for the rest of the TTL.
  defp cacheable?({:error, _reason}, opts), do: Keyword.get(opts, :cache_errors, true)
  defp cacheable?(_value, _opts), do: true
end
