defmodule Tymeslot.Integrations.HealthCheck.Monitor do
  @moduledoc """
  Domain: Health State Tracking & Status Intelligence

  Tracks integration health over time and determines status transitions.
  Provides intelligence about when integrations move between healthy,
  degraded, and unhealthy states.

  Health state is persisted to the `integration_health_states` table so
  that tracking survives process restarts.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis
  alias Tymeslot.Integrations.HealthCheck.HealthStatus
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema

  @failure_threshold 3
  @recovery_threshold 2
  # Consecutive failed sync cycles after which the integration is forced
  # unhealthy regardless of what the scheduled probe says. CalDAV syncs every
  # ~15 minutes, so ten of them is roughly two and a half hours of sustained
  # failure — the same order as the probe's own three-strikes-at-30-to-60-
  # minutes, and far short of the eleven days integration 97 went unnoticed.
  @default_sync_failure_threshold 10
  @check_interval :timer.minutes(30)
  @max_backoff_ms :timer.hours(1)
  # On the very first transition into :unhealthy, override the standard 1 h
  # hard backoff with a quick 15-minute re-probe. This catches the common case
  # where the user fixes their integration server-side immediately after the
  # third probe fails — without the override, the badge would persist for up
  # to an hour even though the integration is already working again.
  # Subsequent failed probes while still :unhealthy revert to the 1 h cadence
  # so we don't hammer a genuinely broken server.
  @first_unhealthy_recovery_probe_ms :timer.minutes(15)

  @type health_status :: :healthy | :degraded | :unhealthy
  @type integration_type :: :calendar | :video
  @type health_state :: %{
          user_id: integer() | nil,
          failures: non_neg_integer(),
          consecutive_hard_failures: non_neg_integer(),
          consecutive_sync_failures: non_neg_integer(),
          successes: non_neg_integer(),
          last_check_at: DateTime.t() | nil,
          status: health_status(),
          backoff_ms: pos_integer(),
          last_error_class: :transient | :hard | nil,
          became_unhealthy_at: DateTime.t() | nil,
          notification_sent_at: DateTime.t() | nil
        }

  @type transition ::
          {:initial_failure | :became_unhealthy | :became_healthy | :became_degraded | :no_change,
           health_status() | nil, health_status()}

  @doc """
  Creates an initial health state for a new integration.
  """
  @spec initial_state() :: health_state()
  def initial_state do
    %{
      user_id: nil,
      failures: 0,
      consecutive_hard_failures: 0,
      consecutive_sync_failures: 0,
      successes: 0,
      last_check_at: nil,
      status: :healthy,
      backoff_ms: @check_interval,
      last_error_class: nil,
      became_unhealthy_at: nil,
      notification_sent_at: nil
    }
  end

  @doc """
  Gets the health state for an integration from the database.
  Creates a default healthy record if none exists.
  """
  @spec get_state(integration_type(), integer(), integer()) :: health_state()
  def get_state(type, integration_id, user_id) do
    case IntegrationHealthStateQueries.get_or_init(type, integration_id, user_id) do
      {:ok, record} -> from_db_record(record)
      {:error, :not_found} -> initial_state()
    end
  end

  @doc """
  Persists the health state for an integration to the database.
  Updates the existing record (created by get_state/get_or_init) with a
  single atomic statement; a no-op if the row was deleted concurrently
  (e.g. by `Scheduler.schedule_all/1`'s orphan cleanup, or a cascading user
  deletion). `health_state.status` is closed to `HealthStatus.values/0` by
  `to_db_attrs/1` (via `HealthStatus.to_db_value/1`, which pattern-matches
  only the valid atoms) before it ever reaches this call, and the
  `status_must_be_known` database constraint backstops it.
  """
  @spec put_state(integration_type(), integer(), health_state()) :: {non_neg_integer(), nil}
  def put_state(type, integration_id, health_state) do
    attrs = to_db_attrs(health_state)
    IntegrationHealthStateQueries.update_fields(type, integration_id, Map.to_list(attrs))
  end

  @doc """
  Updates health state based on check result and error analysis.
  Returns the new health state.

  The probe's own verdict is never the last word: `apply_sync_failure_floor/1`
  holds the row at `:unhealthy` while periodic sync is failing in a streak, so
  a probe that passes cannot clear a badge raised by
  `record_sync_failure/1`. See that function for why the two signals disagree.
  """
  @spec update_health(health_state(), {:ok, any()} | {:error, any(), :transient | :hard}) ::
          health_state()
  def update_health(health_state, analyzed_result) do
    health_state
    |> apply_probe_result(analyzed_result)
    |> apply_sync_failure_floor()
  end

  @doc """
  Records one failed sync cycle and returns the new health state.

  Sync failures are tracked separately from probe failures because they are
  evidence the probe cannot produce. The probe PROPFINDs a collection; sync
  issues a REPORT against it. A server can answer one and refuse the other —
  Infomaniak did, 500ing every incremental REPORT for a CalDAV integration for
  eleven days while the collection answered everything else — and in that state
  the probe is honestly, uselessly healthy. Once the streak reaches
  `sync_failure_threshold/0` the row is forced `:unhealthy` so the badge, the
  48-hour notification and the auto-pause sweep all see the outage.

  The streak is cleared by `IntegrationHealthStateQueries.clear_sync_failures/2`,
  which a successful sync reaches through
  `HealthCheck.mark_synced_successfully/2`. That clears the counter and nothing
  else: recovery of the *status*, and of `became_unhealthy_at` with it, is left
  to the probe, so the existing flap protection in `determine_status/3` still
  governs how quickly a badge clears and one lucky sync a day cannot keep
  restarting the 48-hour notification clock.

  `consecutive_hard_failures` is deliberately untouched: that counter drives
  `SyncGating`, and a remote 5xx is exactly the case where pausing sync would
  stop the integration ever discovering the server had recovered.
  """
  @spec record_sync_failure(health_state()) :: health_state()
  def record_sync_failure(health_state) do
    apply_sync_failure_floor(%{
      health_state
      | consecutive_sync_failures: health_state.consecutive_sync_failures + 1
    })
  end

  @doc """
  Consecutive failed sync cycles after which an integration is forced
  `:unhealthy`. Configurable via `:sync_failure_unhealthy_threshold` for tests.
  """
  @spec sync_failure_threshold() :: pos_integer()
  def sync_failure_threshold do
    Application.get_env(
      :tymeslot,
      :sync_failure_unhealthy_threshold,
      @default_sync_failure_threshold
    )
  end

  @doc """
  Persists the sync-failure streak, and the status it may have forced, for an
  integration.

  Writes only the three fields a sync outcome owns rather than going through
  `put_state/3`. The probe and a sync run concurrently, and each reads its
  state before writing it, so a full-row write from either would silently drop
  the other's update; keeping the two writers to disjoint columns means the
  worst case is a status write landing twice, not a streak going missing.
  """
  @spec put_sync_state(integration_type(), integer(), health_state()) ::
          {non_neg_integer(), nil}
  def put_sync_state(type, integration_id, health_state) do
    IntegrationHealthStateQueries.update_fields(type, integration_id,
      consecutive_sync_failures: health_state.consecutive_sync_failures,
      status: HealthStatus.to_db_value(health_state.status),
      became_unhealthy_at: health_state.became_unhealthy_at
    )
  end

  # A streak of failing syncs outranks a passing probe: the probe tests a
  # request the failing one is not. Nothing here lowers a status — a streak
  # that has ended simply stops raising one, and the next probe reconciles.
  defp apply_sync_failure_floor(health_state) do
    if health_state.consecutive_sync_failures >= sync_failure_threshold() do
      %{
        health_state
        | status: :unhealthy,
          became_unhealthy_at: health_state.became_unhealthy_at || DateTime.utc_now()
      }
    else
      health_state
    end
  end

  defp apply_probe_result(health_state, {:ok, _check_result}) do
    %{
      health_state
      | failures: 0,
        consecutive_hard_failures: 0,
        successes: health_state.successes + 1,
        last_check_at: DateTime.utc_now(),
        status: determine_status(0, health_state.successes + 1, health_state.status),
        backoff_ms: @check_interval,
        last_error_class: nil
    }
  end

  defp apply_probe_result(health_state, {:error, _error_reason, :transient}) do
    new_backoff = ErrorAnalysis.calculate_next_backoff(health_state, :transient)

    # When backoff has reached max, the same transient error has persisted across
    # multiple checks (e.g. econnrefused for over an hour). Start incrementing
    # the failure counter so the integration eventually reaches :unhealthy and
    # triggers the 48h user notification.
    if health_state.backoff_ms >= @max_backoff_ms do
      failures = health_state.failures + 1
      new_status = determine_status(failures, 0, health_state.status)

      became_unhealthy_at =
        if new_status == :unhealthy and is_nil(health_state.became_unhealthy_at),
          do: DateTime.utc_now(),
          else: health_state.became_unhealthy_at

      %{
        health_state
        | failures: failures,
          consecutive_hard_failures: 0,
          successes: 0,
          last_check_at: DateTime.utc_now(),
          status: new_status,
          backoff_ms: new_backoff,
          last_error_class: :transient,
          became_unhealthy_at: became_unhealthy_at
      }
    else
      %{
        health_state
        | consecutive_hard_failures: 0,
          last_check_at: DateTime.utc_now(),
          backoff_ms: new_backoff,
          last_error_class: :transient
      }
    end
  end

  defp apply_probe_result(health_state, {:error, _error_reason, :hard}) do
    failures = health_state.failures + 1
    consecutive_hard_failures = health_state.consecutive_hard_failures + 1
    new_status = determine_status(failures, 0, health_state.status)
    just_became_unhealthy? = new_status == :unhealthy and health_state.status != :unhealthy

    new_backoff =
      if just_became_unhealthy? do
        @first_unhealthy_recovery_probe_ms
      else
        ErrorAnalysis.calculate_next_backoff(health_state, :hard)
      end

    became_unhealthy_at =
      if new_status == :unhealthy and is_nil(health_state.became_unhealthy_at),
        do: DateTime.utc_now(),
        else: health_state.became_unhealthy_at

    %{
      health_state
      | failures: failures,
        consecutive_hard_failures: consecutive_hard_failures,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: new_status,
        backoff_ms: new_backoff,
        last_error_class: :hard,
        became_unhealthy_at: became_unhealthy_at
    }
  end

  @doc """
  Determines the health status from the failure and success counts and the
  status the integration held before this probe.

  `previous_status` is what separates "recovering" from "never broken". The
  recovery threshold is flap protection: it stops an integration that has been
  failing from being declared healthy again on one lucky probe. It is not a
  probation period for integrations that have never failed, so a healthy
  integration whose probe succeeds stays healthy immediately.
  """
  @spec determine_status(non_neg_integer(), non_neg_integer(), health_status()) :: health_status()
  def determine_status(failures, _successes, _previous) when failures >= @failure_threshold,
    do: :unhealthy

  def determine_status(failures, _successes, _previous) when failures > 0, do: :degraded
  def determine_status(_failures, _successes, :healthy), do: :healthy

  def determine_status(_failures, successes, _previous) when successes >= @recovery_threshold,
    do: :healthy

  def determine_status(_failures, _successes, _previous), do: :degraded

  @doc """
  Detects transitions between health states.
  Returns a tuple describing the transition type and old/new status.
  """
  @spec detect_transition(health_state(), health_state()) :: transition()
  def detect_transition(old_state, new_state) do
    case {old_state.last_check_at, old_state.status, new_state.status} do
      # Initial check that fails
      {nil, _old_status, :unhealthy} ->
        {:initial_failure, nil, :unhealthy}

      # Initial check that's healthy or degraded (no action needed)
      {nil, _old_status, status} when status != :unhealthy ->
        {:no_change, nil, status}

      # Transition to unhealthy
      {_last_check_at, old, :unhealthy} when old != :unhealthy ->
        {:became_unhealthy, old, :unhealthy}

      # Recovery to healthy (from unhealthy or degraded)
      {_last_check_at, old, :healthy} when old in [:unhealthy, :degraded] ->
        {:became_healthy, old, :healthy}

      # Degradation from healthy
      {_last_check_at, :healthy, :degraded} ->
        {:became_degraded, :healthy, :degraded}

      # No significant transition
      _other ->
        {:no_change, old_state.status, new_state.status}
    end
  end

  @doc """
  Builds a health report for all integrations belonging to a user.
  Reads current health state from the database.
  """
  @spec build_user_report(integer()) :: map()
  def build_user_report(user_id) do
    calendar_integrations = CalendarIntegrationQueries.list_all_for_user(user_id)
    video_integrations = VideoIntegrationQueries.list_all_for_user(user_id)

    calendar_health =
      Enum.map(calendar_integrations, fn integration ->
        health =
          case IntegrationHealthStateQueries.get(:calendar, integration.id) do
            {:ok, record} -> from_db_record(record)
            {:error, :not_found} -> initial_state()
          end

        %{
          id: integration.id,
          provider: integration.provider,
          is_active: integration.is_active,
          health: health
        }
      end)

    video_health =
      Enum.map(video_integrations, fn integration ->
        health =
          case IntegrationHealthStateQueries.get(:video, integration.id) do
            {:ok, record} -> from_db_record(record)
            {:error, :not_found} -> initial_state()
          end

        %{
          id: integration.id,
          provider: integration.provider,
          is_active: integration.is_active,
          health: health
        }
      end)

    %{
      calendar_integrations: calendar_health,
      video_integrations: video_health,
      summary: %{
        healthy_count: count_by_status([calendar_health, video_health], :healthy),
        degraded_count: count_by_status([calendar_health, video_health], :degraded),
        unhealthy_count: count_by_status([calendar_health, video_health], :unhealthy)
      }
    }
  end

  @doc """
  Converts a database record into a health_state map with atom values.
  """
  @spec from_db_record(IntegrationHealthStateSchema.t()) :: health_state()
  def from_db_record(%IntegrationHealthStateSchema{} = record) do
    %{
      user_id: record.user_id,
      failures: record.failures,
      consecutive_hard_failures: record.consecutive_hard_failures,
      consecutive_sync_failures: record.consecutive_sync_failures,
      successes: record.successes,
      last_check_at: record.last_check_at,
      status: safe_to_status(record.status, record),
      backoff_ms: record.backoff_ms,
      last_error_class: safe_to_error_class(record.last_error_class),
      became_unhealthy_at: record.became_unhealthy_at,
      notification_sent_at: record.notification_sent_at
    }
  end

  # Private Functions

  # `consecutive_sync_failures` is absent by design: the probe never changes it
  # and this map is written as a whole-row update, so including it would let a
  # probe that read the row before a sync failure erase that failure's count.
  # `put_sync_state/3` is the only writer.
  defp to_db_attrs(health_state) do
    base = %{
      status: HealthStatus.to_db_value(health_state.status),
      failures: health_state.failures,
      consecutive_hard_failures: health_state.consecutive_hard_failures,
      successes: health_state.successes,
      backoff_ms: health_state.backoff_ms,
      last_check_at: health_state.last_check_at,
      last_error_class:
        health_state.last_error_class && Atom.to_string(health_state.last_error_class),
      became_unhealthy_at: health_state.became_unhealthy_at,
      notification_sent_at: health_state.notification_sent_at
    }

    case health_state[:user_id] do
      nil -> base
      user_id -> Map.put(base, :user_id, user_id)
    end
  end

  # The canonical status set lives in `HealthCheck.HealthStatus`, and the
  # `status_must_be_known` database constraint closes it for every writer,
  # so a row with a status outside that set means the invariant broke
  # upstream — an operator edit, a restored backup predating the
  # constraint, or a status retired by a rolled-back release. This is a
  # read path reached from the scheduling sweep and dashboard rendering, so
  # it must stay total: log and degrade gracefully rather than raise. The
  # coerced value self-heals on the next `put_state/3` write for that row.
  defp safe_to_status(str, record) when is_binary(str) do
    case HealthStatus.parse(str) do
      {:ok, status} ->
        status

      :error ->
        Logger.error("Unrecognised integration health status in database, defaulting to degraded",
          integration_type: record.integration_type,
          integration_id: record.integration_id,
          status: str
        )

        :degraded
    end
  end

  @valid_error_classes ~w(transient hard)a
  @error_classes_by_name Map.new(@valid_error_classes, &{Atom.to_string(&1), &1})

  defp safe_to_error_class(nil), do: nil

  defp safe_to_error_class(str) when is_binary(str),
    do: Map.get(@error_classes_by_name, str, :hard)

  defp count_by_status(integration_lists, status) do
    integration_lists
    |> List.flatten()
    |> Enum.count(fn integration ->
      integration.health.status == status
    end)
  end
end
