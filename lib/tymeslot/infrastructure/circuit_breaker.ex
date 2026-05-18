defmodule Tymeslot.Infrastructure.CircuitBreaker do
  @moduledoc """
  Implements a circuit breaker pattern for external service calls.

  The circuit breaker has three states:
  - Closed: Normal operation, requests pass through
  - Open: Service is down, requests fail immediately
  - Half-open: Testing if service recovered, limited requests allowed
  """

  use GenServer
  require Logger
  alias Tymeslot.Infrastructure.Metrics

  @default_config %{
    failure_threshold: 5,
    time_window: :timer.minutes(1),
    recovery_timeout: :timer.minutes(5),
    half_open_requests: 3
  }

  @idle_timeout :timer.hours(24)

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
      :half_open_attempts
    ]
  end

  # Client API

  @doc """
  Starts a circuit breaker with the given name and configuration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    config = Keyword.get(opts, :config, %{})

    GenServer.start_link(__MODULE__, {name, config}, name: name)
  end

  @doc """
  Executes a function through the circuit breaker.

  Returns:
  - `:ok` if the function returns bare `:ok`
  - `{:ok, result}` if the function returns `{:ok, result}` or any other non-error value
  - `{:error, :circuit_open}` if the circuit is open
  - `{:error, reason}` if the function fails
  """
  @spec call(GenServer.server(), (-> any())) :: :ok | {:ok, any()} | {:error, any()}
  def call(breaker_name, fun) when is_function(fun, 0) do
    # Use a longer timeout to accommodate HTTP requests (max is 60s for REPORT + some buffer)
    GenServer.call(breaker_name, {:call, fun}, 70_000)
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
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(breaker_name) do
    GenServer.cast(breaker_name, :reset)
  end

  # Server Callbacks

  @impl GenServer
  def init({name, user_config}) do
    config = Map.merge(@default_config, user_config)

    base_state = %State{
      name: name,
      config: config,
      status: :closed,
      failure_count: 0,
      success_count: 0,
      window_start: System.monotonic_time(:millisecond),
      last_failure_time: nil,
      half_open_attempts: 0
    }

    state = restore_state(name, base_state)
    {:ok, state, @idle_timeout}
  end

  @impl GenServer
  def handle_call({:call, fun}, _from, state) do
    result =
      case state.status do
        :open ->
          handle_open_circuit(fun, state)

        :half_open ->
          handle_half_open_circuit(fun, state)

        :closed ->
          handle_closed_circuit(fun, state)
      end

    case result do
      {:reply, response, new_state} ->
        persist_state(new_state)
        {:reply, response, new_state, @idle_timeout}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status_info = %{
      status: state.status,
      failure_count: state.failure_count,
      success_count: state.success_count,
      config: state.config
    }

    {:reply, status_info, state, @idle_timeout}
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
        half_open_attempts: 0
    }

    persist_state(new_state)
    {:noreply, new_state, @idle_timeout}
  end

  # Private Functions

  defp handle_open_circuit(fun, state) do
    now = System.monotonic_time(:millisecond)
    time_since_failure = now - (state.last_failure_time || now)

    if time_since_failure >= state.config.recovery_timeout do
      # Transition to half-open
      Logger.info("Circuit breaker transitioning to half-open", name: state.name)

      Metrics.track_circuit_breaker_state(state.name, :open, :half_open)

      new_state = %{state | status: :half_open, half_open_attempts: 0}

      execute_function_in_half_open(fun, new_state)
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  defp handle_half_open_circuit(fun, state) do
    if state.half_open_attempts >= state.config.half_open_requests do
      # Too many attempts in half-open, go back to open
      Logger.warning("Circuit breaker returning to open - too many half-open attempts",
        name: state.name
      )

      new_state = %{state | status: :open, last_failure_time: System.monotonic_time(:millisecond)}

      {:reply, {:error, :circuit_open}, new_state}
    else
      execute_function_in_half_open(fun, state)
    end
  end

  defp handle_closed_circuit(fun, state) do
    # Check if we need to reset the time window
    now = System.monotonic_time(:millisecond)
    state = maybe_reset_window(state, now)

    case execute_function(fun) do
      :ok ->
        new_state = %{state | success_count: state.success_count + 1}
        {:reply, :ok, new_state}

      {:ok, result} ->
        new_state = %{state | success_count: state.success_count + 1}
        {:reply, {:ok, result}, new_state}

      {:error, _reason} = error ->
        new_state = record_failure(state, now)

        if new_state.failure_count >= new_state.config.failure_threshold do
          Logger.error("Circuit breaker opening - threshold exceeded",
            name: state.name,
            failures: new_state.failure_count,
            threshold: new_state.config.failure_threshold
          )

          Metrics.track_circuit_breaker_state(state.name, :closed, :open)

          opened_state = %{new_state | status: :open, last_failure_time: now}

          {:reply, error, opened_state}
        else
          {:reply, error, new_state}
        end
    end
  end

  defp execute_function_in_half_open(fun, state) do
    new_state = %{state | half_open_attempts: state.half_open_attempts + 1}

    case execute_function(fun) do
      :ok ->
        half_open_success_reply(:ok, new_state, state)

      {:ok, _result} = success ->
        half_open_success_reply(success, new_state, state)

      {:error, _reason} = error ->
        # Failure in half-open, go back to open
        Logger.warning("Circuit breaker returning to open - half-open test failed",
          name: state.name
        )

        Metrics.track_circuit_breaker_state(state.name, :half_open, :open)

        opened_state = %{
          new_state
          | status: :open,
            last_failure_time: System.monotonic_time(:millisecond)
        }

        {:reply, error, opened_state}
    end
  end

  defp half_open_success_reply(success, new_state, state) do
    if new_state.half_open_attempts >= state.config.half_open_requests do
      Logger.info("Circuit breaker closing - successful recovery", name: state.name)
      Metrics.track_circuit_breaker_state(state.name, :half_open, :closed)

      closed_state = %{
        new_state
        | status: :closed,
          failure_count: 0,
          success_count: 1,
          window_start: System.monotonic_time(:millisecond),
          half_open_attempts: 0
      }

      {:reply, success, closed_state}
    else
      {:reply, success, new_state}
    end
  end

  defp execute_function(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _result} = success -> success
      {:error, _reason} = error -> error
      # Handle non-standard returns
      result -> {:ok, result}
    end
  rescue
    error ->
      Logger.error("Circuit breaker caught exception", error: inspect(error))
      {:error, error}
  end

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
      half_open_attempts: state.half_open_attempts
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

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.info("Circuit breaker stopping due to inactivity", name: state.name)

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    # In tests, Swoosh's TestAdapter sends {:email, email} messages to the process that calls deliver.
    # When deliver is wrapped in a circuit breaker, this GenServer receives those messages.
    Logger.debug("Circuit breaker received unexpected message",
      name: state.name,
      message: inspect(msg)
    )

    {:noreply, state, @idle_timeout}
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
