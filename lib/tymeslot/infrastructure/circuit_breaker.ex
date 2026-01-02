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
  - `{:ok, result}` if the function succeeds
  - `{:error, :circuit_open}` if the circuit is open
  - `{:error, reason}` if the function fails
  """
  @spec call(atom(), (-> any())) :: {:ok, any()} | {:error, any()}
  def call(breaker_name, fun) when is_function(fun, 0) do
    # Use a longer timeout to accommodate HTTP requests (max is 60s for REPORT + some buffer)
    GenServer.call(breaker_name, {:call, fun}, 70_000)
  end

  @doc """
  Gets the current status of the circuit breaker.
  """
  @spec status(atom()) :: map()
  def status(breaker_name) do
    GenServer.call(breaker_name, :status, 5_000)
  end

  @doc """
  Resets the circuit breaker to closed state.
  """
  @spec reset(atom()) :: :ok
  def reset(breaker_name) do
    GenServer.cast(breaker_name, :reset)
  end

  # Server Callbacks

  @impl true
  def init({name, user_config}) do
    config = Map.merge(@default_config, user_config)

    state = %State{
      name: name,
      config: config,
      status: :closed,
      failure_count: 0,
      success_count: 0,
      window_start: System.monotonic_time(:millisecond),
      last_failure_time: nil,
      half_open_attempts: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:call, fun}, _from, state) do
    case state.status do
      :open ->
        handle_open_circuit(fun, state)

      :half_open ->
        handle_half_open_circuit(fun, state)

      :closed ->
        handle_closed_circuit(fun, state)
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status_info = %{
      status: state.status,
      failure_count: state.failure_count,
      success_count: state.success_count,
      config: state.config
    }

    {:reply, status_info, state}
  end

  @impl true
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

    {:noreply, new_state}
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
      {:ok, result} ->
        # Success in half-open, check if we can close the circuit
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

          {:reply, {:ok, result}, closed_state}
        else
          {:reply, {:ok, result}, new_state}
        end

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

  defp execute_function(fun) do
    case fun.() do
      {:ok, _} = success -> success
      {:error, _} = error -> error
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

  @impl true
  def handle_info(msg, state) do
    # In tests, Swoosh's TestAdapter sends {:email, email} messages to the process that calls deliver.
    # When deliver is wrapped in a circuit breaker, this GenServer receives those messages.
    Logger.debug("Circuit breaker #{state.name} received message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
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
