defmodule Tymeslot.Integrations.HealthCheck do
  @moduledoc """
  Health check system for monitoring integration status and automatically
  handling failures.

  ## Architecture

  This module serves as the orchestrator for the health check system, coordinating
  between specialized domain modules:

  - `Monitor`: Tracks health state over time (persisted to DB) and detects status transitions
  - `Scheduler`: Determines when checks should run (backoff, jitter, circuit breakers)
  - `Assessor`: Executes health checks for different integration types
  - `ErrorAnalysis`: Classifies errors and determines recovery strategies
  - `ResponseHandler`: Takes action on health status changes (user notification after 48h)

  ## Orchestration Value

  This module provides:
  - GenServer lifecycle management for periodic scheduling
  - Public API surface for the health check system
  - Integration with Oban worker for async execution
  - Coordination of the check flow: Schedule → Assess → Analyze → Monitor → Respond

  Health state is persisted to the `integration_health_states` table so it
  survives process restarts.

  ## Required Database Indexes

  For optimal duplicate job detection performance on large installations:

      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_oban_jobs_args_gin
        ON oban_jobs USING gin (args);

  This GIN index supports JSONB field queries used for duplicate detection.
  Without it, queries may be slow on systems with thousands of pending jobs.
  """

  use GenServer
  require Logger

  alias Tymeslot.DatabaseQueries.{
    CalendarIntegrationQueries,
    IntegrationHealthStateQueries,
    VideoIntegrationQueries
  }

  alias Tymeslot.Integrations.HealthCheck.{
    Assessor,
    ErrorAnalysis,
    Monitor,
    ResponseHandler,
    Scheduler
  }

  @check_interval :timer.minutes(30)

  # Type definitions
  @type health_status :: Monitor.health_status()
  @type integration_type :: Monitor.integration_type()
  @type health_state :: Monitor.health_state()

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            check_timer: reference() | nil
          }
    defstruct check_timer: nil
  end

  # Client API

  @doc """
  Performs a single health check for an integration.
  Called by Oban worker.

  ## Orchestration Flow

  1. Fetch integration from database
  2. Get current health state from Monitor (DB-backed)
  3. Use Assessor to test the integration
  4. Use ErrorAnalysis to classify results
  5. Update health state via Monitor
  6. Detect transitions via Monitor
  7. Persist new state to DB via Monitor
  8. Handle transitions via ResponseHandler
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
  Queries the database directly; does not go through the GenServer.
  """
  @spec get_health_status(integration_type(), integer()) :: health_state() | nil
  def get_health_status(type, integration_id) do
    case IntegrationHealthStateQueries.get(type, integration_id) do
      {:ok, record} -> Monitor.from_db_record(record)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Gets health report for all integrations of a user.
  Queries the database directly; does not go through the GenServer.
  """
  @spec get_user_health_report(integer()) :: map()
  def get_user_health_report(user_id) do
    Monitor.build_user_report(user_id)
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :check_interval, @check_interval)
    initial_delay = Keyword.get(opts, :initial_delay, 1000)

    if initial_delay > 0 do
      Process.send_after(self(), :scheduled_check, initial_delay)
    end

    state = %State{
      check_timer: schedule_next_check(interval)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:check_all, _from, state) do
    Logger.info("Manual health check triggered for all integrations")
    Scheduler.schedule_all(force: true)
    {:reply, :ok, state}
  end

  def handle_call({:perform_single_check, type, id}, _from, state) do
    result = orchestrate_health_check(type, id)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:scheduled_check, state) do
    Logger.debug("Scheduling health check jobs for all integrations")

    Scheduler.schedule_all()

    timer = schedule_next_check(@check_interval)

    {:noreply, %{state | check_timer: timer}}
  end

  # Private Functions — Orchestration Logic

  @spec orchestrate_health_check(integration_type(), integer()) :: :ok | {:error, any()}
  defp orchestrate_health_check(type, id) do
    integration_result =
      case type do
        :calendar -> CalendarIntegrationQueries.get(id)
        :video -> VideoIntegrationQueries.get(id)
      end

    case integration_result do
      {:ok, integration} ->
        # Step 1: Get current health state from DB (creates default record if absent)
        old_health_state = Monitor.get_state(type, id, integration.user_id)

        # Step 2: Use Assessor to test the integration
        {check_result, _duration} = Assessor.assess(type, integration)

        # Step 3: Use ErrorAnalysis to classify the result
        analyzed_result = ErrorAnalysis.analyze(check_result, old_health_state)

        # Step 4: Update health state (pure — does not persist)
        new_health_state = Monitor.update_health(old_health_state, analyzed_result)

        # Step 5: Detect status transition
        transition = Monitor.detect_transition(old_health_state, new_health_state)

        # Step 6: Persist new health state to DB
        Monitor.put_state(type, id, new_health_state)

        # Step 7: Handle transition (logging, user notification)
        ResponseHandler.handle_transition(type, integration, transition, new_health_state)

        case check_result do
          {:error, _reason} = error -> error
          _ok -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  @spec schedule_next_check(pos_integer()) :: reference()
  defp schedule_next_check(interval) do
    Process.send_after(self(), :scheduled_check, interval)
  end
end
