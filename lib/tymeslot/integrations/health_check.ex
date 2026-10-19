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
  - Scheduling, through `Scheduler` run by `IntegrationHealthSweepWorker`
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

  @behaviour Tymeslot.Integrations.HealthCheck.HealthCheckBehaviour

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Shared.IntegrationTypes
  alias Tymeslot.Repo
  alias Tymeslot.Workers.IntegrationHealthWorker

  alias Tymeslot.Integrations.HealthCheck.{
    Assessor,
    ErrorAnalysis,
    Monitor,
    ResponseHandler
  }

  # Type definitions
  @type health_status :: Monitor.health_status()
  @type integration_type :: Monitor.integration_type()
  @type health_state :: Monitor.health_state()

  # Client API

  @doc """
  Performs a single health check for an integration.
  Called by `IntegrationHealthWorker`, so checks run concurrently, one job each.

  ## Orchestration Flow

  1. Fetch integration from database
  2. Get current health state from Monitor (DB-backed)
  3. Use Assessor to test the integration
  4. Use ErrorAnalysis to classify results
  5. Update health state via Monitor
  6. Detect transitions via Monitor
  7. Persist new state to DB via Monitor
  8. Respond via ResponseHandler: flag a permanent auth failure for
     reconnection, then handle the transition
  """
  @impl Tymeslot.Integrations.HealthCheck.HealthCheckBehaviour
  @spec perform_single_check(integration_type(), integer()) :: :ok | {:error, any()}
  def perform_single_check(type, integration_id) do
    Logger.debug("Performing single health check", type: type, id: integration_id)
    orchestrate_health_check(type, integration_id)
  end

  @doc """
  The unhealthy health states of a user's active integrations, by kind and
  then integration id: what the dashboard's badges and attention list read.
  An integration absent from its map is not unhealthy.
  """
  @spec health_states_for_user(integer()) :: %{
          calendar: %{integer() => health_state()},
          video: %{integer() => health_state()}
        }
  def health_states_for_user(user_id) do
    grouped =
      user_id
      |> IntegrationHealthStateQueries.list_unhealthy_for_user()
      |> Enum.group_by(& &1.integration_type)

    Map.new(IntegrationTypes.kinds(), fn kind ->
      records = Map.get(grouped, IntegrationTypes.db_value(kind), [])
      {kind, Map.new(records, &{&1.integration_id, Monitor.from_db_record(&1)})}
    end)
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
  a successful sync: a sync is the integration's own periodic work rather than
  a deliberate act by its owner, so it clears the failed-sync streak without
  declaring the integration recovered.

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
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  @doc """
  Records that one sync cycle for this integration completed, ending whatever
  streak of failed cycles `record_sync_failure/2` had been building.

  It clears the streak counter and nothing else. One successful cycle says the
  streak has ended; it does not say the outage has, and the two are different
  claims for a server that refuses most syncs while answering the occasional
  one. Resetting the whole row here would restart the 48-hour notification
  clock on every such success, so the badge would flap and the owner would
  never be told. Declaring the integration healthy again is left to the probe's
  flap-protected recovery path, which is also what clears
  `became_unhealthy_at`; see
  `IntegrationHealthStateQueries.clear_sync_failures/2`.

  Unlike `mark_user_recovered/2`, this does not enqueue a probe: the scheduled
  one will arrive on its own, and a sync cycle is not the owner waiting on an
  answer.

  Idempotent and safe to call when no row exists.
  """
  @spec mark_synced_successfully(integration_type(), integer()) :: :ok
  def mark_synced_successfully(type, integration_id) do
    IntegrationHealthStateQueries.clear_sync_failures(type, integration_id)
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
    {:ok, {old_health_state, new_health_state}} =
      Repo.transaction(fn ->
        old_health_state = Monitor.get_state_for_update(type, integration.id, integration.user_id)
        new_health_state = Monitor.record_sync_failure(old_health_state)
        Monitor.put_sync_state(type, integration.id, new_health_state)
        {old_health_state, new_health_state}
      end)

    transition = Monitor.detect_transition(old_health_state, new_health_state)
    ResponseHandler.handle_transition(type, integration, transition, new_health_state)

    :ok
  end

  # Private Functions — Orchestration Logic

  @spec orchestrate_health_check(integration_type(), integer()) :: :ok | {:error, any()}
  defp orchestrate_health_check(type, id) do
    case IntegrationTypes.queries(type).get(id) do
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
        IntegrationTypes.domain(type).handle_reauth_required(integration)
        :ok
    end
  end

  # Steps 1, 3-8 of the orchestration flow described in the moduledoc, run
  # for every check result except a rate-limited refusal (see
  # `orchestrate_health_check/2`).
  @spec update_health_state(integration_type(), integer(), map(), {:ok, any()} | {:error, any()}) ::
          :ok | {:error, any()}
  defp update_health_state(type, id, integration, check_result) do
    # Steps 1, 3, 4 and 6 under the row lock, so a sync of the same
    # integration cannot write between this read and this write (see
    # `Monitor.get_state_for_update/3`): read the current health state
    # (creating a default record if absent), classify the result, fold it in,
    # and persist.
    {:ok, {old_health_state, new_health_state}} =
      Repo.transaction(fn ->
        old_health_state = Monitor.get_state_for_update(type, id, integration.user_id)

        analyzed_result =
          ErrorAnalysis.analyze(check_result, old_health_state,
            type: type,
            integration_id: id,
            provider: integration.provider
          )

        new_health_state = Monitor.update_health(old_health_state, analyzed_result)
        Monitor.put_state(type, id, new_health_state)
        {old_health_state, new_health_state}
      end)

    # Step 5: Detect status transition
    transition = Monitor.detect_transition(old_health_state, new_health_state)

    # Steps 7-8: Fast-path immediate reauth + notification on permanent auth
    # failures (e.g. Google `invalid_grant`), which cannot recover without user
    # action, then the transition (logging, user notification after 48h). The
    # fast-path runs first so the transition sees a freshly flagged integration
    # and does not send the unhealthy email on top of the reauth one.
    ResponseHandler.handle_check_result(
      type,
      integration,
      transition,
      new_health_state,
      check_result
    )

    case check_result do
      {:error, _reason} = error -> error
      _ok -> :ok
    end
  end
end
