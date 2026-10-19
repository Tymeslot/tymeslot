defmodule Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries do
  @moduledoc """
  Database queries for integration health state persistence.

  Provides read and write operations for the `integration_health_states` table,
  which stores the current health monitoring state for each calendar and video
  integration so that state survives process restarts.
  """

  import Ecto.Query

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.HealthCheck.HealthStatus
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Shared.IntegrationTypes

  alias Tymeslot.Repo

  @doc """
  Retrieves the health state record for a specific integration.
  Returns `{:ok, record}` or `{:error, :not_found}`.
  """
  @spec get(String.t() | atom(), integer()) ::
          {:ok, IntegrationHealthStateSchema.t()} | {:error, :not_found}
  def get(type, integration_id) do
    type_str = to_string(type)

    case Repo.get_by(IntegrationHealthStateSchema,
           integration_type: type_str,
           integration_id: integration_id
         ) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Inserts the default health state for every active integration of `kind`
  that has none, in one statement. Returns the number inserted.

  The sweep runs it first, so `due/2` can read health states alone.
  """
  @spec seed_missing(IntegrationTypes.kind()) :: non_neg_integer()
  def seed_missing(kind) do
    type_str = IntegrationTypes.db_value(kind)
    now = DateTime.truncate(Clock.utc_now(), :second)

    missing =
      from(i in IntegrationTypes.queries(kind).active_query(),
        left_join: s in IntegrationHealthStateSchema,
        on: s.integration_type == ^type_str and s.integration_id == i.id,
        where: is_nil(s.id),
        select: %{
          integration_type: ^type_str,
          integration_id: i.id,
          user_id: i.user_id,
          status: ^HealthStatus.to_db_value(:healthy),
          failures: 0,
          consecutive_hard_failures: 0,
          consecutive_sync_failures: 0,
          successes: 0,
          backoff_ms: ^IntegrationHealthStateSchema.check_interval_ms(),
          inserted_at: ^now,
          updated_at: ^now
        }
      )

    {count, _rows} =
      Repo.insert_all(IntegrationHealthStateSchema, missing,
        on_conflict: :nothing,
        conflict_target: [:integration_type, :integration_id]
      )

    count
  end

  @doc """
  The active integrations of `kind` whose next health check is due at `now`:
  never checked, or checked longer ago than their backoff.

  Reads health states through `integration_health_states_next_check_index`,
  whose expression the comparison below repeats exactly, so the cost follows
  the number of due rows rather than the number of integrations. Selects only
  what scheduling needs; credentials stay in the table.
  """
  @spec due(IntegrationTypes.kind(), DateTime.t()) :: [
          %{id: integer(), provider: String.t(), base_url: String.t() | nil}
        ]
  def due(kind, %DateTime{} = now) do
    type_str = IntegrationTypes.db_value(kind)
    now = DateTime.to_naive(now)

    Repo.all(
      from(s in IntegrationHealthStateSchema,
        join: i in subquery(IntegrationTypes.queries(kind).active_query()),
        on: i.id == s.integration_id,
        where: s.integration_type == ^type_str,
        where:
          fragment(
            "(COALESCE(?, '-infinity'::timestamp) + ? * interval '1 millisecond') <= ?",
            s.last_check_at,
            s.backoff_ms,
            ^now
          ),
        select: %{id: i.id, provider: i.provider, base_url: i.base_url}
      )
    )
  end

  @doc """
  Retrieves or initialises the health state record for an integration.

  If no record exists, inserts a default healthy state using `on_conflict: :nothing`
  and returns the (possibly just-created) record.
  """
  @spec get_or_init(String.t() | atom(), integer(), integer()) ::
          {:ok, IntegrationHealthStateSchema.t()} | {:error, :not_found}
  def get_or_init(type, integration_id, user_id) do
    type_str = to_string(type)

    seed_attrs = %{
      integration_type: type_str,
      integration_id: integration_id,
      user_id: user_id,
      status: HealthStatus.to_db_value(:healthy),
      failures: 0,
      consecutive_hard_failures: 0,
      consecutive_sync_failures: 0,
      successes: 0,
      backoff_ms: IntegrationHealthStateSchema.check_interval_ms()
    }

    %IntegrationHealthStateSchema{}
    |> IntegrationHealthStateSchema.changeset(seed_attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:integration_type, :integration_id])

    case Repo.get_by(IntegrationHealthStateSchema,
           integration_type: type_str,
           integration_id: integration_id
         ) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  `get_or_init/3`, then the row read again under `FOR UPDATE`, so a caller
  inside a transaction holds it until that transaction ends.

  The probe and a sync of one integration both read the row, work out the new
  state and write it back. Each doing so under this lock means neither can
  write over a state the other wrote after it read.
  """
  @spec get_or_init_for_update(String.t() | atom(), integer(), integer()) ::
          {:ok, IntegrationHealthStateSchema.t()} | {:error, :not_found}
  def get_or_init_for_update(type, integration_id, user_id) do
    type_str = to_string(type)

    with {:ok, _record} <- get_or_init(type, integration_id, user_id) do
      case Repo.one(
             from(s in IntegrationHealthStateSchema,
               where: s.integration_type == ^type_str and s.integration_id == ^integration_id,
               lock: "FOR UPDATE"
             )
           ) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  @doc """
  Updates specific fields on an existing health state record.
  Only updates if a record already exists (no INSERT). Safe to call
  concurrently — a genuinely atomic single statement, so a row deleted
  between caller and call (orphan cleanup, a cascading user deletion) is a
  clean no-op rather than a raise.
  Returns the number of records updated (0 if no record exists).

  A `status` value outside `HealthStatus.values/0` is rejected by the
  `status_must_be_known` database constraint. Every writer, including
  `Monitor.put_state/3` (the sole path that writes a runtime-derived
  status), goes through this one function.
  """
  @spec update_fields(String.t() | atom(), integer(), keyword()) :: {non_neg_integer(), nil}
  def update_fields(type, integration_id, field_updates) do
    type_str = to_string(type)

    Repo.update_all(
      from(s in IntegrationHealthStateSchema,
        where: s.integration_type == ^type_str and s.integration_id == ^integration_id
      ),
      set: field_updates ++ [updated_at: Clock.utc_now()]
    )
  end

  @doc """
  Resets the health state row to a known-healthy baseline.

  Used when the user has produced an unambiguous success signal — a credentials
  update or a reactivation — that proves the integration works regardless of
  what the last scheduled probe said. Without this, the in-app badge can lag the
  truth by up to an hour while waiting for the next scheduled probe.

  A successful *sync* is deliberately not one of those signals: it calls
  `clear_sync_failures/2` instead, which zeroes the streak and leaves the
  unhealthy episode standing. See that function for why.

  `successes` counts consecutive successful probes, and a reset has run none,
  so it starts at zero like every other counter here. It needs no head start
  towards the recovery threshold: the row is written as healthy, and
  `Monitor.determine_status/3` keeps a healthy row healthy on its next
  success. Any probe that does leave the row non-healthy zeroes the counter on
  its way, so a seeded value could never be read.

  Safe to call when no row exists (no-op).
  """
  @spec reset(String.t() | atom(), integer()) :: {non_neg_integer(), nil}
  def reset(type, integration_id) do
    update_fields(type, integration_id,
      status: HealthStatus.to_db_value(:healthy),
      failures: 0,
      consecutive_hard_failures: 0,
      consecutive_sync_failures: 0,
      successes: 0,
      backoff_ms: IntegrationHealthStateSchema.check_interval_ms(),
      last_check_at: Clock.utc_now(),
      last_error_class: nil,
      became_unhealthy_at: nil,
      notification_sent_at: nil
    )
  end

  @doc """
  Clears the failed-sync streak after a sync cycle completes.

  This is the whole reset path for `consecutive_sync_failures`, the counter
  `Monitor.record_sync_failure/1` raises the unhealthy badge from: nothing else
  zeroes it.

  It writes that one column and nothing else, and the omissions are the point.
  `status`, `became_unhealthy_at` and `notification_sent_at` describe an
  unhealthy *episode*, and a single successful sync is not evidence the episode
  has ended — a server that refuses most syncs while succeeding about once a day
  is exactly the case the streak exists to catch. Clearing them here would
  restart the 48-hour notification clock on every one of those successes, so the
  badge would flap daily and the owner's email would never fire.

  Ending the episode is the probe's job: two consecutive successful probes take
  the row back to `:healthy` through the flap protection in
  `Monitor.determine_status/3`, and the resulting `:became_healthy` transition
  is where `ResponseHandler` clears the timestamps. Keeping recovery in that one
  place is why this function does not attempt its own.

  Safe to call when no row exists (no-op).
  """
  @spec clear_sync_failures(String.t() | atom(), integer()) :: {non_neg_integer(), nil}
  def clear_sync_failures(type, integration_id) do
    update_fields(type, integration_id, consecutive_sync_failures: 0)
  end

  @doc """
  Deletes health state records whose integration no longer exists.
  Runs a NOT IN subquery per integration type.
  """
  @spec delete_orphaned() :: {non_neg_integer(), nil}
  def delete_orphaned do
    deleted =
      IntegrationTypes.kinds()
      |> Enum.map(&delete_orphaned_by_type/1)
      |> Enum.sum_by(&elem(&1, 0))

    {deleted, nil}
  end

  @doc """
  Returns all unhealthy integration health state records for a user that
  belong to a still-active integration.

  Rows are filtered against the underlying integration tables so that a stale
  `:unhealthy` row left behind on an integration the user has deactivated does
  not produce a phantom badge. Once the user reactivates, the calling layer is
  expected to call `reset/2` (via `HealthCheck.mark_user_recovered/2`) so the
  next probe reconciles state with reality.
  """
  @spec list_unhealthy_for_user(integer()) :: [IntegrationHealthStateSchema.t()]
  def list_unhealthy_for_user(user_id) do
    of_active_integration =
      Enum.reduce(IntegrationTypes.kinds(), dynamic(false), fn kind, acc ->
        active_ids = where(active_integration_ids_subquery(kind), user_id: ^user_id)

        dynamic(
          [s],
          ^acc or
            (s.integration_type == ^IntegrationTypes.db_value(kind) and
               s.integration_id in subquery(active_ids))
        )
      end)

    Repo.all(
      from(s in IntegrationHealthStateSchema,
        where: s.user_id == ^user_id and s.status == ^HealthStatus.to_db_value(:unhealthy),
        where: ^of_active_integration
      )
    )
  end

  @doc """
  Returns currently-unhealthy health-state rows of the given type that match
  *either* of the auto-pause triggers:

    * `became_unhealthy_at < calendar_cutoff` — the current unhealthy streak
      has been going for at least the calendar cutoff (default 14 days).
      Catches flappy / intermittently broken integrations.

    * `consecutive_hard_failures >= hard_failure_count` — the integration
      has hit at least this many back-to-back hard failures with no successes
      mixed in. Catches "token revoked, server is gone, nothing transient is
      happening" cases much earlier than the calendar trigger.

  Used by `Tymeslot.Workers.IntegrationAutoPauseWorker`. Both triggers carry
  the same outcome (pause + notify) but the worker logs which one fired.
  """
  @spec list_pausable(String.t() | atom(), DateTime.t(), non_neg_integer()) ::
          [IntegrationHealthStateSchema.t()]
  def list_pausable(type, %DateTime{} = calendar_cutoff, hard_failure_count)
      when is_integer(hard_failure_count) and hard_failure_count >= 0 do
    {:ok, kind} = IntegrationTypes.parse(type)
    type_str = IntegrationTypes.db_value(kind)
    active_ids = active_integration_ids_subquery(kind)

    IntegrationHealthStateSchema
    |> where(
      [s],
      s.integration_type == ^type_str and
        s.status == ^HealthStatus.to_db_value(:unhealthy) and
        s.integration_id in subquery(active_ids) and
        ((not is_nil(s.became_unhealthy_at) and s.became_unhealthy_at < ^calendar_cutoff) or
           s.consecutive_hard_failures >= ^hard_failure_count)
    )
    |> Repo.all()
  end

  @doc """
  Returns integration IDs of the given type that have hit at least
  `threshold` consecutive hard failures. Used by
  `Tymeslot.Integrations.HealthCheck.SyncGating` to pause periodic sync
  work for integrations whose OAuth token is clearly broken.

  Filters on `consecutive_hard_failures` (resets to 0 on any success or
  transient error) so that a mixed history of transient and hard failures
  does not incorrectly pause an integration.
  """
  @spec list_ids_with_sustained_hard_failures(String.t() | atom(), non_neg_integer()) ::
          [integer()]
  def list_ids_with_sustained_hard_failures(type, threshold) do
    type_str = to_string(type)

    IntegrationHealthStateSchema
    |> where(
      [s],
      s.integration_type == ^type_str and
        s.last_error_class == "hard" and
        s.consecutive_hard_failures >= ^threshold
    )
    |> select([s], s.integration_id)
    |> Repo.all()
  end

  defp active_integration_ids_subquery(kind),
    do: select(IntegrationTypes.queries(kind).active_query(), [i], i.id)

  defp delete_orphaned_by_type(kind) do
    orphaned_query =
      from(s in IntegrationHealthStateSchema,
        where: s.integration_type == ^IntegrationTypes.db_value(kind),
        where:
          s.integration_id not in subquery(from(i in IntegrationTypes.schema(kind), select: i.id))
      )

    Repo.delete_all(orphaned_query)
  end
end
