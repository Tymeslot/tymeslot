defmodule Tymeslot.Infrastructure.CircuitBreaker do
  @moduledoc """
  Implements a circuit breaker pattern for external service calls.

  The circuit breaker has three states:
  - Closed: Normal operation, requests pass through
  - Open: Service is down, requests fail immediately
  - Half-open: Testing if service recovered, limited requests allowed

  ## The protected work runs in the caller, not in this process

  `call/2` asks this GenServer for permission, runs the function itself, and
  reports the outcome back asynchronously. It does **not** hand the function
  over to be executed here.

  That distinction is the whole point. A breaker that executes the work inside
  its own process turns itself into a lock: every caller of a given provider
  queues behind one mailbox, so protecting a dependency would cap concurrency
  on it at one. The breaker only ever holds state, so its calls are
  bookkeeping and return immediately.

  The cost is that an outcome arrives after the fact, so a burst of callers can
  be granted permission before any of them has reported. `half_open_requests`
  is not a concurrency cap: it is a cumulative grant ceiling for the current
  half-open round, counting every permission handed out since the round
  started and never decremented as outcomes report back. Raising it therefore
  lengthens how many sequential grants a round permits before it stalls, not
  how many probes may run at once. The circuit closes once that many
  successes have been recorded, rather than that many attempts granted. A
  caller that dies without reporting simply never counts; a probe round that
  stalls entirely is restarted once `recovery_timeout` has passed, so the
  breaker cannot wedge on a permission it handed out and never heard about.
  """

  use GenServer, restart: :transient
  require Logger
  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Metrics

  @typedoc """
  What a protected call resolves to.

  `normalize_result/1` passes the calendar clients' three-element
  `{:error, reason, message}` through deliberately, so it belongs in the
  contract; leaving it out told Dialyzer that every caller matching on it was
  writing dead code.
  """
  @type result ::
          :ok
          | {:ok, any()}
          | {:error, any()}
          | {:error, any(), any()}
          | {:provider_error, any()}

  @default_config %{
    failure_threshold: 5,
    time_window: :timer.minutes(1),
    recovery_timeout: :timer.minutes(5),
    half_open_requests: 3
  }

  # Only applied when a caller opts in via `:idle_timeout` (see `start_link/1`).
  # Statically supervised breakers (the per-provider and email/OAuth ones
  # started by `CircuitBreakerSupervisor`) never pass this, so they default to
  # `:infinity` and are never idle-stopped: with `restart: :transient`, a
  # `:normal` idle stop is not restarted, so arming a finite timeout on a
  # breaker with no dynamic-supervisor lifecycle would kill it for the life of
  # the node the first time it goes quiet for this long. Dynamically started
  # per-host breakers (`CalendarCircuitBreaker`/`VideoCircuitBreaker`
  # `call_with_host/3`) opt in explicitly so a stale host row doesn't linger
  # in the shared ETS table forever.
  @idle_timeout :timer.hours(24)

  # This call only reads and updates counters, so it can be short.
  @permission_timeout :timer.seconds(5)

  # Shared ETS table — owned by `CircuitBreakerSupervisor` so entries survive
  # this GenServer crashing and being restarted on the same BEAM. On init we
  # restore any snapshot for our `name`, so a recovering external service still
  # sees `:open` / `:half_open` rather than being hammered with a fresh
  # `:closed` + zero-failure budget. Does NOT survive a BEAM restart, node
  # shutdown, or deploy.
  @state_table :circuit_breaker_state_table

  defmodule State do
    @moduledoc false
    defstruct [
      :name,
      :config,
      :status,
      :failure_count,
      :success_count,
      :window_start,
      :last_failure_time,
      :half_open_attempts,
      :half_open_successes,
      :half_open_started_at,
      :idle_timeout
    ]
  end

  # Client API

  @doc """
  Starts a circuit breaker with the given name and configuration.

  ## Options
  - `:idle_timeout` - how long the breaker may go without a message before it
    stops itself and drops its persisted snapshot. Defaults to `:infinity`
    (never idle-stops), which is correct for a statically supervised, named
    breaker. Pass `default_idle_timeout/0` (or another finite value) only for
    a breaker started dynamically per host, where an idle stop is a
    deliberate reap rather than a failure.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    config = Keyword.get(opts, :config, %{})
    idle_timeout = Keyword.get(opts, :idle_timeout, :infinity)

    GenServer.start_link(__MODULE__, {name, config, idle_timeout}, name: name)
  end

  @doc """
  The idle timeout dynamically started (per-host) breakers should opt into so
  a host that goes quiet for this long is reaped rather than kept alive
  forever. See `start_link/1`'s `:idle_timeout` option.
  """
  @spec default_idle_timeout() :: pos_integer()
  def default_idle_timeout, do: @idle_timeout

  @doc """
  Executes a function through the circuit breaker.

  Returns:
  - `:ok` if the function returns bare `:ok`
  - `{:ok, result}` if the function returns `{:ok, result}` or any other non-error value
  - `{:error, :circuit_open}` if the circuit is open
  - `{:provider_error, reason}` if the function returns that explicitly
  - `{:error, reason}` if the function fails

  ## Options
  - `:classify` - a `(term() -> BreakerOutcome.outcome())` function applied to
    the (normalised) return value to decide whether it should trip the
    breaker (`:failure`), count towards closing it (`:success`), or leave
    breaker state untouched (`:ignore`, e.g. a local validation error or a
    4xx that says nothing about the provider's health). Defaults to
    `BreakerOutcome.classify/1`.

  An exception raised by the function itself is not evidence the provider is
  down, so it is always classified `:ignore` regardless of `:classify`; an
  `exit` or `throw` is recorded the same way and then re-raised, so the
  breaker is never left blind by a termination path that skips reporting.
  """
  @spec call(GenServer.server(), (-> any()), keyword()) :: result()
  def call(breaker_name, fun, opts \\ []) when is_function(fun, 0) do
    classify_fun = Keyword.get(opts, :classify, &BreakerOutcome.classify/1)

    # Bookkeeping only, so this returns without waiting on anything external.
    # The function itself runs here, in the caller, and its outcome is reported
    # back after the fact.
    case GenServer.call(breaker_name, :request_permission, @permission_timeout) do
      :allow ->
        run_protected(breaker_name, fun, classify_fun)

      {:error, :circuit_open} = refusal ->
        refusal
    end
  end

  defp run_protected(breaker_name, fun, classify_fun) do
    {result, outcome} = execute_function(fun, classify_fun)
    GenServer.cast(breaker_name, {:record_outcome, outcome})
    result
  catch
    kind, reason ->
      Logger.error("Circuit breaker caught a non-local exit",
        name: breaker_name,
        kind: kind,
        reason: inspect(reason)
      )

      GenServer.cast(breaker_name, {:record_outcome, :ignore})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Gets the current status of the circuit breaker.
  """
  @spec status(GenServer.server()) :: map()
  def status(breaker_name) do
    GenServer.call(breaker_name, :status, 5_000)
  end

  @doc """
  Resets the circuit breaker to closed state.

  Clears the persisted ETS snapshot directly (not just via the cast) so a
  reset issued while the breaker process is down or restarting cannot be
  silently dropped and resurrect a stale `:open` snapshot on the next start.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(breaker_name) do
    safe_ets_delete(@state_table, breaker_name)
    GenServer.cast(breaker_name, :reset)
  end

  # Server Callbacks

  @impl GenServer
  def init({name, user_config, idle_timeout}) do
    config = Map.merge(@default_config, user_config)

    base_state = %State{
      name: name,
      config: config,
      status: :closed,
      failure_count: 0,
      success_count: 0,
      window_start: System.monotonic_time(:millisecond),
      last_failure_time: nil,
      half_open_attempts: 0,
      half_open_successes: 0,
      half_open_started_at: nil,
      idle_timeout: idle_timeout
    }

    state = restore_state(name, base_state)
    {:ok, state, state.idle_timeout}
  end

  @impl GenServer
  def handle_call(:request_permission, _from, state) do
    {reply, new_state} = grant_permission(state)
    persist_state(new_state)
    {:reply, reply, new_state, new_state.idle_timeout}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status_info = %{
      status: state.status,
      failure_count: state.failure_count,
      success_count: state.success_count,
      config: state.config
    }

    {:reply, status_info, state, state.idle_timeout}
  end

  @impl GenServer
  def handle_cast({:record_outcome, outcome}, state) do
    new_state = record_outcome(outcome, state)
    persist_state(new_state)
    {:noreply, new_state, new_state.idle_timeout}
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    Logger.info("Circuit breaker reset", name: state.name)

    new_state = %{
      state
      | status: :closed,
        failure_count: 0,
        success_count: 0,
        window_start: System.monotonic_time(:millisecond),
        last_failure_time: nil,
        half_open_attempts: 0,
        half_open_successes: 0,
        half_open_started_at: nil
    }

    persist_state(new_state)
    {:noreply, new_state, new_state.idle_timeout}
  end

  # Private Functions

  # Permission granting: decides whether a caller may run, and records the
  # state transitions that decision implies. Outcomes arrive separately.

  defp grant_permission(%State{status: :closed} = state) do
    {:allow, maybe_reset_window(state, System.monotonic_time(:millisecond))}
  end

  defp grant_permission(%State{status: :open} = state) do
    now = System.monotonic_time(:millisecond)

    if now - (state.last_failure_time || now) >= state.config.recovery_timeout do
      Logger.info("Circuit breaker transitioning to half-open", name: state.name)
      Metrics.track_circuit_breaker_state(state.name, :open, :half_open)

      {:allow, %{start_half_open_round(state, now) | status: :half_open}}
    else
      {{:error, :circuit_open}, state}
    end
  end

  defp grant_permission(%State{status: :half_open} = state) do
    now = System.monotonic_time(:millisecond)

    cond do
      state.half_open_attempts < state.config.half_open_requests ->
        {:allow, %{state | half_open_attempts: state.half_open_attempts + 1}}

      # Every probe of this round was granted and none came back. Rather than
      # deny for ever, start a fresh round once the recovery window has passed
      # again.
      now - (state.half_open_started_at || now) >= state.config.recovery_timeout ->
        Logger.warning("Circuit breaker half-open round stalled, probing again",
          name: state.name
        )

        {:allow, start_half_open_round(state, now)}

      true ->
        {{:error, :circuit_open}, state}
    end
  end

  defp start_half_open_round(state, now) do
    %{state | half_open_attempts: 1, half_open_successes: 0, half_open_started_at: now}
  end

  # Outcome recording: the caller ran the work and is telling us how it went.

  # An outcome that says nothing about the provider's health (a local
  # validation error, a 4xx, a nested `:circuit_open`) must not trip the
  # breaker and must not count towards closing it either. In `:closed` and
  # `:open` that means state is left completely untouched; in `:half_open` it
  # additionally releases the grant it consumed, otherwise a single ignored
  # probe permanently spends one of the round's slots and the round can never
  # reach enough successes to close.
  defp record_outcome(:ignore, %State{status: :half_open} = state) do
    %{state | half_open_attempts: max(state.half_open_attempts - 1, 0)}
  end

  defp record_outcome(:ignore, state), do: state

  defp record_outcome(:success, %State{status: :closed} = state) do
    %{state | success_count: state.success_count + 1}
  end

  defp record_outcome(:failure, %State{status: :closed} = state) do
    now = System.monotonic_time(:millisecond)
    new_state = record_failure(state, now)

    if new_state.failure_count >= new_state.config.failure_threshold do
      Logger.error("Circuit breaker opening - threshold exceeded",
        name: state.name,
        failures: new_state.failure_count,
        threshold: new_state.config.failure_threshold
      )

      Metrics.track_circuit_breaker_state(state.name, :closed, :open)

      %{new_state | status: :open, last_failure_time: now}
    else
      new_state
    end
  end

  defp record_outcome(:success, %State{status: :half_open} = state) do
    successes = state.half_open_successes + 1

    if successes >= state.config.half_open_requests do
      Logger.info("Circuit breaker closing - successful recovery", name: state.name)
      Metrics.track_circuit_breaker_state(state.name, :half_open, :closed)

      %{
        state
        | status: :closed,
          failure_count: 0,
          success_count: 1,
          window_start: System.monotonic_time(:millisecond),
          half_open_attempts: 0,
          half_open_successes: 0,
          half_open_started_at: nil
      }
    else
      %{state | half_open_successes: successes}
    end
  end

  defp record_outcome(:failure, %State{status: :half_open} = state) do
    Logger.warning("Circuit breaker returning to open - half-open test failed",
      name: state.name
    )

    Metrics.track_circuit_breaker_state(state.name, :half_open, :open)

    %{
      state
      | status: :open,
        last_failure_time: System.monotonic_time(:millisecond),
        half_open_attempts: 0,
        half_open_successes: 0,
        half_open_started_at: nil
    }
  end

  # A probe granted before the circuit re-opened, reporting in afterwards. The
  # transition it would have caused has already happened.
  defp record_outcome(_outcome, %State{status: :open} = state), do: state

  defp execute_function(fun, classify_fun) do
    result = normalize_result(fun.())
    {result, normalize_outcome(classify_fun.(result))}
  rescue
    error ->
      # An exception out of our own code is not evidence the provider is
      # down, so it is never classified `:failure` — but it must still be
      # reported (as `:ignore`) so the breaker isn't left blind.
      Logger.error("Circuit breaker caught exception", error: inspect(error))
      {{:error, error}, :ignore}
  end

  # A caller-supplied `:classify` function is not guaranteed to return one of
  # the three valid outcomes; an unrecognised value must not reach
  # `record_outcome/2`, which would crash the breaker (shared by every caller
  # of that provider) with a `FunctionClauseError`.
  defp normalize_outcome(outcome) when outcome in [:success, :failure, :ignore], do: outcome

  defp normalize_outcome(other) do
    Logger.warning(
      "Circuit breaker classifier returned an unrecognised outcome, treating as :ignore",
      outcome: inspect(other)
    )

    :ignore
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _result} = success), do: success
  # The calendar clients report errors as a 3-element `{:error, reason,
  # message}` tuple. Left unmatched here it would fall to the catch-all below
  # and be wrapped as `{:ok, _}`, so every calendar transport failure and 5xx
  # would be scored a `:success` and the breaker could never open.
  defp normalize_result({:error, _reason, _message} = error), do: error
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result({:provider_error, _reason} = error), do: error
  # Handle non-standard returns
  defp normalize_result(result), do: {:ok, result}

  defp maybe_reset_window(state, now) do
    if now - state.window_start >= state.config.time_window do
      %{state | failure_count: 0, success_count: 0, window_start: now}
    else
      state
    end
  end

  defp record_failure(state, now) do
    %{state | failure_count: state.failure_count + 1, last_failure_time: now}
  end

  defp persist_state(%State{name: name} = state) do
    snapshot = %{
      status: state.status,
      failure_count: state.failure_count,
      success_count: state.success_count,
      window_start: state.window_start,
      last_failure_time: state.last_failure_time,
      half_open_attempts: state.half_open_attempts,
      half_open_successes: state.half_open_successes,
      half_open_started_at: state.half_open_started_at
    }

    safe_ets_insert(@state_table, {name, snapshot})
    state
  end

  defp restore_state(name, base_state) do
    case safe_ets_lookup(@state_table, name) do
      [{^name, snapshot}] -> Map.merge(base_state, snapshot)
      _other -> base_state
    end
  end

  # `:ets.whereis/1` guards against test environments that haven't started the
  # application (and therefore haven't created the table). Without it the first
  # test to touch a breaker crashes with `:badarg`.
  defp safe_ets_insert(table, entry) do
    if :ets.whereis(table) != :undefined do
      :ets.insert(table, entry)
    end

    :ok
  end

  defp safe_ets_lookup(table, key) do
    if :ets.whereis(table) != :undefined do
      :ets.lookup(table, key)
    else
      []
    end
  end

  defp safe_ets_delete(table, key) do
    if :ets.whereis(table) != :undefined do
      :ets.delete(table, key)
    end

    :ok
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.info("Circuit breaker stopping due to inactivity", name: state.name)

    # Only reachable when this breaker was started with a finite
    # `:idle_timeout` (the dynamically started per-host breakers). `restart:
    # :transient` (see `use GenServer` above) means this `:normal` stop is not
    # immediately restarted, so the reap is real: drop the persisted snapshot
    # too, otherwise a dynamic per-host breaker that goes idle leaves its row
    # in the shared ETS table forever.
    safe_ets_delete(@state_table, state.name)

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    # Nothing routes replies here any more now that protected work runs in the
    # caller, but a stray message must not take the breaker down with it.
    Logger.debug("Circuit breaker received unexpected message",
      name: state.name,
      message: inspect(msg)
    )

    {:noreply, state, state.idle_timeout}
  end

  @impl GenServer
  def format_status(_reason, [_pdict, state]) do
    [
      data: [
        {"State",
         %{
           status: state.status,
           failure_count: state.failure_count,
           success_count: state.success_count,
           config: state.config
         }}
      ]
    ]
  end
end
