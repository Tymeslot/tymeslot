defmodule Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries do
  @moduledoc """
  Database queries for integration health state persistence.

  Provides get/upsert operations for the `integration_health_states` table,
  which stores the current health monitoring state for each calendar and video
  integration so that state survives process restarts.
  """

  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

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
      status: "healthy",
      failures: 0,
      consecutive_hard_failures: 0,
      successes: 0,
      backoff_ms: 1_800_000
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
  Upserts the health state for an integration.

  Replaces all provided fields on conflict against the `[integration_type, integration_id]`
  unique index. Returns `{:ok, record}` on success.
  """
  @spec upsert(String.t() | atom(), integer(), map()) ::
          {:ok, IntegrationHealthStateSchema.t()} | {:error, any()}
  def upsert(type, integration_id, attrs) do
    type_str = to_string(type)
    replace_fields = Map.keys(attrs) ++ [:updated_at]

    attrs_with_identity =
      attrs
      |> Map.put(:integration_type, type_str)
      |> Map.put(:integration_id, integration_id)

    %IntegrationHealthStateSchema{}
    |> IntegrationHealthStateSchema.upsert_changeset(attrs_with_identity)
    |> Repo.insert(
      on_conflict: {:replace, replace_fields},
      conflict_target: [:integration_type, :integration_id],
      returning: true
    )
  end

  @doc """
  Updates specific fields on an existing health state record.
  Only updates if a record already exists (no INSERT). Safe to call concurrently.
  Returns the number of records updated (0 if no record exists).
  """
  @spec update_fields(String.t() | atom(), integer(), keyword()) :: {non_neg_integer(), nil}
  def update_fields(type, integration_id, field_updates) do
    type_str = to_string(type)

    Repo.update_all(
      from(s in IntegrationHealthStateSchema,
        where: s.integration_type == ^type_str and s.integration_id == ^integration_id
      ),
      set: field_updates ++ [updated_at: DateTime.utc_now()]
    )
  end

  @doc """
  Resets the health state row to a known-healthy baseline.

  Used when the user has produced an unambiguous success signal — a successful
  sync, a credentials update, or a reactivation — that proves the integration
  works regardless of what the last scheduled probe said. Without this, the
  in-app badge can lag the truth by up to an hour while waiting for the next
  scheduled probe.

  Safe to call when no row exists (no-op).
  """
  @spec reset(String.t() | atom(), integer()) :: {non_neg_integer(), nil}
  def reset(type, integration_id) do
    update_fields(type, integration_id,
      status: "healthy",
      failures: 0,
      consecutive_hard_failures: 0,
      successes: 2,
      backoff_ms: 1_800_000,
      last_check_at: DateTime.utc_now(),
      last_error_class: nil,
      became_unhealthy_at: nil,
      notification_sent_at: nil
    )
  end

  @doc """
  Deletes health state records whose integration no longer exists.
  Runs a NOT IN subquery per integration type.
  """
  @spec delete_orphaned() :: {non_neg_integer(), nil}
  def delete_orphaned do
    calendar_deleted = delete_orphaned_by_type("calendar", CalendarIntegrationSchema)
    video_deleted = delete_orphaned_by_type("video", VideoIntegrationSchema)

    {elem(calendar_deleted, 0) + elem(video_deleted, 0), nil}
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
    calendar_ids =
      from(c in CalendarIntegrationSchema,
        where: c.user_id == ^user_id and c.is_active == true,
        select: c.id
      )

    video_ids =
      from(v in VideoIntegrationSchema,
        where: v.user_id == ^user_id and v.is_active == true,
        select: v.id
      )

    Repo.all(
      from(s in IntegrationHealthStateSchema,
        where: s.user_id == ^user_id and s.status == "unhealthy",
        where:
          (s.integration_type == "calendar" and s.integration_id in subquery(calendar_ids)) or
            (s.integration_type == "video" and s.integration_id in subquery(video_ids))
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
    type_str = to_string(type)
    active_ids = active_integration_ids_subquery(type, type_str)

    IntegrationHealthStateSchema
    |> where(
      [s],
      s.integration_type == ^type_str and
        s.status == "unhealthy" and
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

  defp active_integration_ids_subquery(:calendar, _type_str),
    do: from(c in CalendarIntegrationSchema, where: c.is_active == true, select: c.id)

  defp active_integration_ids_subquery(:video, _type_str),
    do: from(v in VideoIntegrationSchema, where: v.is_active == true, select: v.id)

  defp active_integration_ids_subquery(type, type_str) when is_binary(type) do
    active_integration_ids_subquery(String.to_existing_atom(type), type_str)
  end

  defp delete_orphaned_by_type(type_str, integration_schema) do
    orphaned_query =
      from(s in IntegrationHealthStateSchema,
        where: s.integration_type == ^type_str,
        where: s.integration_id not in subquery(from(i in integration_schema, select: i.id))
      )

    Repo.delete_all(orphaned_query)
  end
end
