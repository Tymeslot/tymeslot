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
  - Stateless orchestration functions called directly by Oban workers
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
  @behaviour Tymeslot.Integrations.HealthCheck.HealthCheckBehaviour

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Workers.IntegrationHealthWorker

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
  Called directly by Oban workers — does not go through the GenServer,
  so multiple checks can run concurrently without serialising.

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
  @impl Tymeslot.Integrations.HealthCheck.HealthCheckBehaviour
  @spec perform_single_check(integration_type(), integer()) :: :ok | {:error, any()}
  def perform_single_check(type, integration_id) do
    Logger.debug("Performing single health check", type: type, id: integration_id)
    orchestrate_health_check(type, integration_id)
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

  @doc """
  Lists unhealthy health-state records for a user's active integrations.
  Queries the database directly; does not go through the GenServer.
  """
  @spec list_unhealthy_for_user(integer()) :: [IntegrationHealthStateSchema.t()]
  def list_unhealthy_for_user(user_id) do
    IntegrationHealthStateQueries.list_unhealthy_for_user(user_id)
  end

  @doc """
  Canonical attention classification for an integration given its current
  health state, following the single precedence ladder used across the
  dashboard: paused → needs_reauth → unhealthy → healthy.
  """
  @spec attention_status(map(), health_state() | nil) ::
          :paused | :needs_reauth | :unhealthy | :ok
  def attention_status(%{is_active: false}, _health), do: :paused
  def attention_status(%{needs_reauth: true}, _health), do: :needs_reauth
  def attention_status(_integration, %{status: :unhealthy}), do: :unhealthy
  def attention_status(_integration, _health), do: :ok

  @doc """
  Records that the user has produced an unambiguous success signal — fresh
  credentials or a reactivation — and we should treat the integration as
  healthy without waiting for the next scheduled probe.

  Resets the health row to a healthy baseline and enqueues an immediate
  verification probe with no jitter so the state is reconciled with reality
  within seconds. Use `mark_synced_successfully/2` instead when the signal is
  a successful sync — that already proves health, so the extra probe is
  wasted work.

  Idempotent and safe to call when no row exists.
  """
  @spec mark_user_recovered(integration_type(), integer()) :: :ok
  def mark_user_recovered(type, integration_id) do
    IntegrationHealthStateQueries.reset(type, integration_id)

    result =
      %{"type" => Atom.to_string(type), "integration_id" => integration_id}
      |> IntegrationHealthWorker.new()
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue immediate verification probe after user recovery",
          integration_type: type,
          integration_id: integration_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Resets the health state row after a successful sync.

  A real sync is the strongest possible health signal — it actually exercised
  the credentials end-to-end. Without this, the badge can stay stuck on
  `:unhealthy` for up to an hour while syncs are happily working in parallel.

  Unlike `mark_user_recovered/2`, this does not enqueue a probe — sync just
  proved everything works, so re-probing is wasted work.

  Idempotent and safe to call when no row exists.
  """
  @spec mark_synced_successfully(integration_type(), integer()) :: :ok
  def mark_synced_successfully(type, integration_id) do
    IntegrationHealthStateQueries.reset(type, integration_id)
    :ok
  end

  @doc """
  Records that one sync cycle for this integration failed.

  A sync failure is the only evidence some outages produce. The scheduled
  probe and a sync do not issue the same request — for CalDAV the probe
  PROPFINDs the calendar collection while sync issues a REPORT against it —
  and a server can answer one while refusing the other. When that happens the
  probe is honestly healthy and the integration silently stops syncing:
  production carried a CalDAV integration that failed 1015 of 1026 sync
  attempts across eleven days with a green badge and no alert the whole time.

  Feeding the failure into the same pipeline the probe uses means a streak of
  them raises the badge, the 48-hour notification and the auto-pause sweep,
  without touching the deliberate decision that a single failed cycle is not
  worth retrying to exhaustion or paging an operator over. The streak is
  cleared by the successful sync that follows, via
  `mark_synced_successfully/2`.

  Safe to call for any failure reason: reasons that already flag the
  integration for reconnection simply reach the badge by two routes.
  """
  @spec record_sync_failure(integration_type(), map()) :: :ok
  def record_sync_failure(type, integration) do
    old_health_state = Monitor.get_state(type, integration.id, integration.user_id)
    new_health_state = Monitor.record_sync_failure(old_health_state)
    transition = Monitor.detect_transition(old_health_state, new_health_state)

    Monitor.put_sync_state(type, integration.id, new_health_state)
    ResponseHandler.handle_transition(type, integration, transition, new_health_state)

    :ok
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :check_interval, @check_interval)
    initial_delay = Keyword.get(opts, :initial_delay, 1000)

    timer =
      if initial_delay > 0 do
        Process.send_after(self(), :scheduled_check, initial_delay)
      else
        schedule_next_check(interval)
      end

    {:ok, %State{check_timer: timer}}
  end

  @impl GenServer
  def handle_call(:check_all, _from, state) do
    Logger.info("Manual health check triggered for all integrations")
    Scheduler.schedule_all(force: true)
    {:reply, :ok, state}
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
      {:ok, %{is_active: false}} ->
        Logger.debug("Skipping health check for deactivated integration",
          type: type,
          integration_id: id
        )

        :ok

      {:ok, integration} ->
        # Step 2: Use Assessor to test the integration
        {check_result, _duration} = Assessor.assess(type, integration)

        case check_result do
          {:error, {:rate_limited, _message}} ->
            # `ConnectionProbe` refused to even attempt the probe — a
            # background scope is unmetered by construction, so this should
            # be unreachable in practice, but a probe that never ran is not
            # a probe that failed: never touch health state, backoff, or
            # failure counters for it.
            Logger.info("Skipping health state update for rate-limited probe",
              type: type,
              integration_id: id
            )

            :ok

          _other ->
            update_health_state(type, id, integration, check_result)
        end

      {:error, :not_found} ->
        :ok

      {:error, :requires_reencryption, integration} ->
        case type do
          :calendar -> CalendarManagement.handle_reauth_required(integration)
          :video -> Video.handle_reauth_required(integration)
        end

        :ok
    end
  end

  # Steps 1, 3-8 of the orchestration flow described in the moduledoc, run
  # for every check result except a rate-limited refusal (see
  # `orchestrate_health_check/2`).
  @spec update_health_state(integration_type(), integer(), map(), {:ok, any()} | {:error, any()}) ::
          :ok | {:error, any()}
  defp update_health_state(type, id, integration, check_result) do
    # Step 1: Get current health state from DB (creates default record if absent)
    old_health_state = Monitor.get_state(type, id, integration.user_id)

    # Step 3: Use ErrorAnalysis to classify the result
    analyzed_result = ErrorAnalysis.analyze(check_result, old_health_state)

    # Step 4: Update health state (pure — does not persist)
    new_health_state = Monitor.update_health(old_health_state, analyzed_result)

    # Step 5: Detect status transition
    transition = Monitor.detect_transition(old_health_state, new_health_state)

    # Step 6: Persist new health state to DB
    Monitor.put_state(type, id, new_health_state)

    # Step 7: Handle transition (logging, user notification after 48h)
    ResponseHandler.handle_transition(type, integration, transition, new_health_state)

    # Step 8: Fast-path immediate reauth + notification on permanent auth failures
    # (e.g. Google `invalid_grant`). Bypasses the 48-hour notification threshold
    # because the integration cannot recover without user action.
    ResponseHandler.handle_permanent_auth_failure(type, integration, check_result)

    case check_result do
      {:error, _reason} = error -> error
      _ok -> :ok
    end
  end

  @spec schedule_next_check(pos_integer()) :: reference()
  defp schedule_next_check(interval) do
    Process.send_after(self(), :scheduled_check, interval)
  end
end
