defmodule Tymeslot.Integrations.HealthCheck do
  @moduledoc """
  Health check system for monitoring integration status and automatically
  handling failures.

  ## Architecture

  This module serves as the orchestrator for the health check system, coordinating
  between specialized domain modules:

  - `Monitor`: Tracks health state over time and detects status transitions
  - `Scheduler`: Determines when checks should run (backoff, jitter, circuit breakers)
  - `Assessor`: Executes health checks for different integration types
  - `ErrorAnalysis`: Classifies errors and determines recovery strategies
  - `ResponseHandler`: Takes action on health status changes (deactivate, alert)

  ## Orchestration Value

  This module provides:
  - GenServer lifecycle management and state coordination
  - Public API surface for the health check system
  - Integration with Oban worker for async execution
  - Periodic scheduling of health checks
  - Coordination of the check flow: Schedule → Assess → Analyze → Monitor → Respond

  ## Required Database Indexes

  For optimal duplicate job detection performance on large installations:

      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_oban_jobs_args_gin
        ON oban_jobs USING gin (args);

  This GIN index supports JSONB field queries used for duplicate detection.
  Without it, queries may be slow on systems with thousands of pending jobs.
  """

  use GenServer
  require Logger

  alias Tymeslot.DatabaseQueries.{CalendarIntegrationQueries, VideoIntegrationQueries}

  alias Tymeslot.Integrations.HealthCheck.{
    Assessor,
    ErrorAnalysis,
    Monitor,
    ResponseHandler,
    Scheduler
  }

  @check_interval :timer.minutes(5)

  # Type definitions
  @type health_status :: Monitor.health_status()
  @type integration_type :: Monitor.integration_type()
  @type health_state :: Monitor.health_state()

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            calendar_health: %{integer() => Tymeslot.Integrations.HealthCheck.health_state()},
            video_health: %{integer() => Tymeslot.Integrations.HealthCheck.health_state()},
            check_timer: reference() | nil
          }
    defstruct calendar_health: %{}, video_health: %{}, check_timer: nil
  end

  # Client API

  @doc """
  Performs a single health check for an integration.
  Called by Oban worker.

  ## Orchestration Flow

  1. Fetch integration from database
  2. Get current health state from Monitor
  3. Use Assessor to test the integration
  4. Use ErrorAnalysis to classify results
  5. Update health state via Monitor
  6. Detect transitions via Monitor
  7. Handle transitions via ResponseHandler
  """
  @spec perform_single_check(integration_type(), integer()) :: :ok | {:error, any()}
  def perform_single_check(type, integration_id) do
    Logger.debug("Performing single health check", type: type, id: integration_id)
    GenServer.call(__MODULE__, {:perform_single_check, type, integration_id}, 60_000)
  end

  @doc """
  Starts the health check process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a health check for all integrations.
  Uses Scheduler to enqueue jobs for all active integrations.
  """
  @spec check_all_integrations() :: :ok
  def check_all_integrations do
    GenServer.call(__MODULE__, :check_all)
  end

  @doc """
  Gets the current health status for a specific integration.
  Retrieves the state tracked by Monitor.
  """
  @spec get_health_status(integration_type(), integer()) :: health_state() | nil
  def get_health_status(type, integration_id) do
    GenServer.call(__MODULE__, {:get_health_status, type, integration_id})
  end

  @doc """
  Gets health report for all integrations of a user.
  Delegates to Monitor to build the report.
  """
  @spec get_user_health_report(integer()) :: map()
  def get_user_health_report(user_id) do
    GenServer.call(__MODULE__, {:get_user_health_report, user_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval, @check_interval)
    initial_delay = Keyword.get(opts, :initial_delay, 1000)

    # Schedule first check after a short delay
    if initial_delay > 0 do
      Process.send_after(self(), :scheduled_check, initial_delay)
    end

    state = %State{
      calendar_health: %{},
      video_health: %{},
      check_timer: schedule_next_check(interval)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:check_all, _from, state) do
    Logger.info("Manual health check triggered for all integrations")
    {new_state, _scheduled} = Scheduler.schedule_all(state, force: true)
    {:reply, :ok, new_state}
  end

  def handle_call({:perform_single_check, type, id}, _from, state) do
    {result, new_state} = orchestrate_health_check(type, id, state)
    {:reply, result, new_state}
  end

  def handle_call({:get_health_status, type, id}, _from, state) do
    status = Monitor.get_state(state, type, id)
    {:reply, status, state}
  end

  def handle_call({:get_user_health_report, user_id}, _from, state) do
    report = Monitor.build_user_report(user_id, state)
    {:reply, report, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    Logger.debug("Scheduling health check jobs for all integrations")

    {new_state, _scheduled} = Scheduler.schedule_all(state)

    # Schedule next check
    timer = schedule_next_check(@check_interval)

    {:noreply, %{new_state | check_timer: timer}}
  end

  # Private Functions - Orchestration Logic

  @doc false
  @spec orchestrate_health_check(integration_type(), integer(), State.t()) ::
          {:ok | {:error, any()}, State.t()}
  defp orchestrate_health_check(type, id, state) do
    integration_result =
      case type do
        :calendar -> CalendarIntegrationQueries.get(id)
        :video -> VideoIntegrationQueries.get(id)
      end

    case integration_result do
      {:ok, integration} ->
        # Step 1: Get current health state from Monitor
        old_health_state = Monitor.get_state(state, type, id)

        # Step 2: Use Assessor to test the integration
        {check_result, _duration} = Assessor.assess(type, integration)

        # Step 3: Use ErrorAnalysis to classify the result
        analyzed_result = ErrorAnalysis.analyze(check_result, old_health_state)

        # Step 4: Update health state via Monitor
        new_health_state = Monitor.update_health(old_health_state, analyzed_result)

        # Step 5: Detect status transition via Monitor
        transition = Monitor.detect_transition(old_health_state, new_health_state)

        # Step 6: Handle transition via ResponseHandler
        ResponseHandler.handle_transition(type, integration, transition)

        # Step 7: Update GenServer state
        new_state = Monitor.put_state(state, type, id, new_health_state)

        {check_result, new_state}

      {:error, :not_found} ->
        {:ok, state}
    end
  end

  @spec schedule_next_check(pos_integer()) :: reference()
  defp schedule_next_check(interval) do
    Process.send_after(self(), :scheduled_check, interval)
  end
end
