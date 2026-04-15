defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries do
  @moduledoc """
  Database queries for cached calendar events.

  Provides read and write operations for the provider_calendar_events table, which stores
  events fetched from external calendar providers keyed by (calendar_integration_id, uid).
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @doc """
  Returns all cached events for the given integration IDs within a time range.

  Events are included if they overlap with the [range_start, range_end] window.
  Both timed events (start_at/end_at) and all-day events (start_date/end_date)
  are checked for overlap.
  """
  @spec list_for_range([integer()], DateTime.t(), DateTime.t()) :: [
          ProviderCalendarEventSchema.t()
        ]
  def list_for_range([], _range_start, _range_end), do: []

  def list_for_range(integration_ids, range_start, range_end) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where_overlapping_range(range_start, range_end)
    |> order_by([e], asc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)))
    |> Repo.all()
  end

  @doc """
  Upserts a list of event attribute maps.

  On conflict by (calendar_integration_id, uid) all mutable fields are updated.
  The `id` and `inserted_at` columns are never touched.

  Returns `{:ok, count}` on success or `{:error, reason}` on failure.
  """
  @spec upsert_batch([map()]) :: {:ok, non_neg_integer()}
  def upsert_batch([]), do: {:ok, 0}

  def upsert_batch(events_attrs) do
    now = DateTime.utc_now(:microsecond)

    entries =
      Enum.map(events_attrs, fn attrs ->
        attrs
        |> Map.put_new(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _rows} =
      Repo.insert_all(
        ProviderCalendarEventSchema,
        entries,
        on_conflict: {:replace, replace_fields()},
        conflict_target: [:calendar_integration_id, :uid]
      )

    {:ok, count}
  end

  @doc """
  Returns UIDs of cached events for the given integration within a time window,
  filtered to events synced before the given cutoff.

  When `calendar_path` is provided, only events whose `provider_event_id` starts
  with that path are returned. This scopes deletion detection to a single calendar
  within a multi-calendar integration.
  """
  @spec list_uids_in_range(integer(), DateTime.t(), DateTime.t(), DateTime.t(), String.t() | nil) ::
          [String.t()]
  def list_uids_in_range(
        calendar_integration_id,
        range_start,
        range_end,
        synced_before,
        calendar_path \\ nil
      ) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where_overlapping_range(range_start, range_end)
    |> where([e], e.synced_at < ^synced_before)
    |> maybe_filter_calendar_path(calendar_path)
    |> select([e], e.uid)
    |> Repo.all()
  end

  @doc "Applies a where clause filtering events that overlap the given DateTime range."
  @spec where_overlapping_range(Ecto.Query.t(), DateTime.t(), DateTime.t()) :: Ecto.Query.t()
  def where_overlapping_range(query, range_start, range_end) do
    range_start_date = DateTime.to_date(range_start)
    range_end_date = DateTime.to_date(range_end)

    where(
      query,
      [e],
      (e.all_day == false and e.start_at < ^range_end and e.end_at > ^range_start) or
        (e.all_day == true and e.start_date < ^range_end_date and e.end_date > ^range_start_date)
    )
  end

  defp maybe_filter_calendar_path(query, nil), do: query

  defp maybe_filter_calendar_path(query, calendar_path) do
    escaped = String.replace(calendar_path, ~r/[\\%_]/, "\\\\\\0")
    prefix = escaped <> "%"
    where(query, [e], like(e.provider_event_id, ^prefix))
  end

  @doc "Fetches a single cached event by integration ID and UID."
  @spec get_by_uid(integer(), String.t()) ::
          {:ok, ProviderCalendarEventSchema.t()} | {:error, :not_found}
  def get_by_uid(calendar_integration_id, uid) do
    case Repo.get_by(ProviderCalendarEventSchema,
           calendar_integration_id: calendar_integration_id,
           uid: uid
         ) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @doc """
  Deletes a single event identified by its integration and uid.

  Returns `{:ok, :deleted}` if a row was removed, `{:ok, :not_found}` if nothing matched.
  """
  @spec delete_by_uid(integer(), String.t()) :: {:ok, :deleted | :not_found}
  def delete_by_uid(calendar_integration_id, uid) do
    {count, _rows} =
      ProviderCalendarEventSchema
      |> where(
        [e],
        e.calendar_integration_id == ^calendar_integration_id and e.uid == ^uid
      )
      |> Repo.delete_all()

    if count > 0, do: {:ok, :deleted}, else: {:ok, :not_found}
  end

  @doc """
  Deletes a single event identified by its integration and provider event ID.

  Returns `{:ok, :deleted}` if a row was removed, `{:ok, :not_found}` if nothing matched.
  """
  @spec delete_by_provider_event_id(integer(), String.t()) :: {:ok, :deleted | :not_found}
  def delete_by_provider_event_id(calendar_integration_id, provider_event_id) do
    {count, _rows} =
      ProviderCalendarEventSchema
      |> where(
        [e],
        e.calendar_integration_id == ^calendar_integration_id and
          e.provider_event_id == ^provider_event_id
      )
      |> Repo.delete_all()

    if count > 0, do: {:ok, :deleted}, else: {:ok, :not_found}
  end

  @doc """
  Replaces all cached events for an integration in a single transaction.

  Deletes every existing row for the integration, then inserts the provided
  events. Intended for full-refresh syncs where the local cache must exactly
  match the provider's current state.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec full_refresh_for_integration(integer(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def full_refresh_for_integration(calendar_integration_id, events_attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [2, calendar_integration_id])

      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> Repo.delete_all()

      {:ok, count} = upsert_batch(events_attrs)
      count
    end)
  end

  @doc """
  Deletes cached events that ended before the given cutoff datetime.

  Both timed events (end_at) and all-day events (end_date) are considered.
  Returns the number of deleted rows.
  """
  @spec prune_ended_before(DateTime.t()) :: non_neg_integer()
  def prune_ended_before(cutoff) do
    cutoff_date = DateTime.to_date(cutoff)

    {count, _rows} =
      ProviderCalendarEventSchema
      |> where(
        [e],
        (e.all_day == false and e.end_at < ^cutoff) or
          (e.all_day == true and e.end_date < ^cutoff_date)
      )
      |> Repo.delete_all()

    count
  end

  @doc """
  Lists cache rows with a pending local change for the given integration.

  Used by `OfflineQueue.flush/2` at the start of each sync cycle to
  replay local creates / updates / deletes against the remote server
  before pulling remote changes.

  Returned in ascending `updated_at` order so the oldest pending change
  is replayed first — preserves FIFO semantics across edits to the same
  cached row.
  """
  @spec list_pending(integer()) :: [ProviderCalendarEventSchema.t()]
  def list_pending(calendar_integration_id) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.sync_state != "synced")
    |> order_by([e], asc: e.updated_at)
    |> Repo.all()
  end

  @doc """
  Marks a cache row as successfully replayed to the server.

  Clears `sync_state`, resets `sync_attempts`, records the attempt time,
  and optionally updates the persisted `etag` with the value the server
  returned on the successful write.

  Returns `{:ok, :updated}` if the row existed; `{:ok, :not_found}`
  if no row matched (the row was deleted between `list_pending/1`
  and `mark_synced/3`, which is benign).
  """
  @spec mark_synced(integer(), String.t(), String.t() | nil) ::
          {:ok, :updated | :not_found}
  def mark_synced(calendar_integration_id, uid, new_etag) do
    now = DateTime.utc_now(:microsecond)

    set =
      maybe_put_etag(
        [
          sync_state: "synced",
          sync_attempts: 0,
          sync_last_attempt_at: now,
          sync_last_error: nil,
          updated_at: now
        ],
        new_etag
      )

    {count, _rows} =
      ProviderCalendarEventSchema
      |> where(
        [e],
        e.calendar_integration_id == ^calendar_integration_id and e.uid == ^uid
      )
      |> Repo.update_all(set: set)

    if count > 0, do: {:ok, :updated}, else: {:ok, :not_found}
  end

  @doc """
  Records a failed replay attempt for a pending cache row.

  Increments `sync_attempts`, stamps `sync_last_attempt_at`, and stores
  the formatted error in `sync_last_error`. Does not change
  `sync_state` — the row stays in the queue and will be retried on
  the next sync cycle.
  """
  @spec mark_sync_failed(integer(), String.t(), String.t()) :: :ok
  def mark_sync_failed(calendar_integration_id, uid, reason) when is_binary(reason) do
    now = DateTime.utc_now(:microsecond)

    ProviderCalendarEventSchema
    |> where(
      [e],
      e.calendar_integration_id == ^calendar_integration_id and e.uid == ^uid
    )
    |> Repo.update_all(
      inc: [sync_attempts: 1],
      set: [sync_last_attempt_at: now, sync_last_error: reason]
    )

    :ok
  end

  defp maybe_put_etag(set, nil), do: set
  defp maybe_put_etag(set, etag) when is_binary(etag), do: Keyword.put(set, :etag, etag)

  @doc """
  Deletes all cached events belonging to inactive integrations.

  Returns the number of deleted rows.
  """
  @spec prune_inactive_integrations() :: non_neg_integer()
  def prune_inactive_integrations do
    {count, _rows} =
      ProviderCalendarEventSchema
      |> join(:inner, [e], i in assoc(e, :calendar_integration))
      |> where([_e, i], i.is_active == false)
      |> Repo.delete_all()

    count
  end

  # Fields updated on conflict — everything except the surrogate key, inserted_at,
  # and the identity fields :provider and :provider_calendar_id (which are set at
  # insert time from the integration and must never be overwritten with EXCLUDED
  # values from partial cache-update maps that may omit them).
  #
  # The :sync_state, :sync_attempts, :sync_last_attempt_at and :sync_last_error
  # columns are also deliberately excluded: they track the offline write queue
  # and must survive a server-sourced upsert so OfflineQueue can still
  # replay the local change after the cache row has been refreshed from the
  # server's view.
  defp replace_fields do
    [
      :provider_event_id,
      :summary,
      :description,
      :location,
      :visibility,
      :colour,
      :all_day,
      :start_date,
      :end_date,
      :start_at,
      :end_at,
      :timezone,
      :transparency,
      :status,
      :organiser,
      :attendees,
      :recurrence_rule,
      :recurrence_exceptions,
      :recurring_event_id,
      :attachments,
      :links,
      :reminders,
      :etag,
      :synced_at,
      :provider_updated_at,
      :provider_metadata,
      :raw_ical,
      :updated_at
    ]
  end
end
