defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries do
  @moduledoc """
  Database queries for cached calendar events.

  Provides read and write operations for the provider_calendar_events table, which stores
  events fetched from external calendar providers keyed by (calendar_integration_id, uid).
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @doc """
  Returns all cached events for the given integration IDs within a time range.

  Events are included if they overlap with the [range_start, range_end] window.
  Both timed events (start_at/end_at) and all-day events (start_date/end_date)
  are checked for overlap. Results are ordered by start time ascending.

  ## Options

  - `:limit` — maximum number of rows to return (default: unbounded). Since
    results are ordered ascending by start time, the earliest-starting events
    in the range are the ones kept when a limit is applied.
  """
  @spec list_for_range([integer()], DateTime.t(), DateTime.t(), keyword()) :: [
          ProviderCalendarEventSchema.t()
        ]
  def list_for_range(integration_ids, range_start, range_end, opts \\ [])

  def list_for_range([], _range_start, _range_end, _opts), do: []

  def list_for_range(integration_ids, range_start, range_end, opts) do
    limit = Keyword.get(opts, :limit)

    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where_overlapping_range(range_start, range_end)
    |> order_by([e], asc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)))
    |> maybe_limit(limit)
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  @upcoming_reminder_limit 200

  @doc """
  Returns upcoming *timed* cached events for the given integration IDs whose
  start falls in `[now, window_end)`, ordered by start time and capped.

  Only timed events are returned — all-day events have no meaningful clock time
  to fire a desktop reminder against. Reminder filtering (events that actually
  carry reminders) is done by the caller after normalisation.
  """
  @spec list_upcoming_timed([integer()], DateTime.t(), DateTime.t()) :: [
          ProviderCalendarEventSchema.t()
        ]
  def list_upcoming_timed([], _now, _window_end), do: []

  def list_upcoming_timed(integration_ids, now, window_end) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where([e], e.all_day == false and not is_nil(e.start_at))
    |> where([e], e.start_at >= ^now and e.start_at < ^window_end)
    |> order_by([e], asc: e.start_at)
    |> limit(@upcoming_reminder_limit)
    |> Repo.all()
  end

  @default_search_limit 50

  @doc """
  Searches a user's cached calendar events by a free-text term.

  Performs a case-insensitive `ILIKE` match against the event `summary`,
  `description`, and `location`. Results are scoped to the user's active
  calendar integrations and exclude any integration whose id appears in
  `:hidden_integration_ids`. Matches are ordered by start time ascending
  (timed events by `start_at`, all-day events by `start_date`) and capped
  at `:limit` (default #{@default_search_limit}).

  A blank or whitespace-only term returns `[]` without touching the database.

  ## Options

  - `:hidden_integration_ids` — list of integration ids to exclude (default `[]`).
  - `:limit` — maximum number of rows to return (default #{@default_search_limit}).
  """
  @spec search(integer(), String.t(), keyword()) :: [ProviderCalendarEventSchema.t()]
  def search(user_id, term, opts \\ []) when is_integer(user_id) do
    trimmed = String.trim(to_string(term))

    if trimmed == "" do
      []
    else
      hidden_ids = Keyword.get(opts, :hidden_integration_ids, [])
      limit = Keyword.get(opts, :limit, @default_search_limit)
      pattern = "%" <> escape_like(trimmed) <> "%"

      ProviderCalendarEventSchema
      |> join(:inner, [e], i in assoc(e, :calendar_integration))
      |> where([_e, i], i.user_id == ^user_id and i.is_active == true)
      |> where([e, _i], e.calendar_integration_id not in ^hidden_ids)
      |> where(
        [e, _i],
        ilike(e.summary, ^pattern) or ilike(e.description, ^pattern) or
          ilike(e.location, ^pattern)
      )
      |> order_by([e, _i], asc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)))
      |> limit(^limit)
      |> Repo.all()
    end
  end

  # Escapes LIKE/ILIKE wildcard metacharacters so a user-typed term is matched
  # literally rather than as a pattern.
  defp escape_like(term) do
    String.replace(term, ~r/[\\%_]/, "\\\\\\0")
  end

  @doc """
  Upserts a list of event attribute maps.

  On conflict by (calendar_integration_id, uid) all mutable fields are updated.
  The `id` and `inserted_at` columns are never touched.

  Returns `{:ok, count}` on success or `{:error, reason}` on failure.
  """
  # Rows are inserted in chunks so a single `insert_all` never exceeds
  # PostgreSQL's 65,535 bind-parameter limit. The schema has ~30 insertable
  # columns, so a busy calendar's initial sync (Google requests up to 2,500
  # events per page) would otherwise blow the limit in one statement.
  @upsert_chunk_size 1000

  @spec upsert_batch([map()]) :: {:ok, non_neg_integer()}
  def upsert_batch([]), do: {:ok, 0}

  def upsert_batch(events_attrs) do
    now = DateTime.utc_now(:microsecond)

    # Deduplicate by the conflict key before inserting. Google (and potentially
    # other providers) can return multiple instances of the same recurring event
    # series in a single sync response — all sharing the same iCalUID. PostgreSQL
    # rejects an ON CONFLICT DO UPDATE that targets the same row twice in one
    # command, so we keep the last entry per (calendar_integration_id, uid).
    count =
      events_attrs
      |> Enum.map(fn attrs ->
        attrs
        |> Map.put_new(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)
      |> Enum.reduce(%{}, fn entry, acc ->
        Map.put(acc, {entry.calendar_integration_id, entry.uid}, entry)
      end)
      |> Map.values()
      |> Enum.chunk_every(@upsert_chunk_size)
      |> Enum.reduce(0, fn chunk, acc -> acc + upsert_chunk(chunk) end)

    {:ok, count}
  end

  defp upsert_chunk(entries) do
    {count, _rows} =
      Repo.insert_all(
        ProviderCalendarEventSchema,
        entries,
        on_conflict: {:replace, replace_fields()},
        conflict_target: [:calendar_integration_id, :uid]
      )

    count
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

  @doc """
  Returns, as a `MapSet`, which of the given UIDs the cache currently holds for
  this integration — with no date range applied at all.

  The reconcile sweep's second question, and the reason it is separate from
  `list_uids_in_range/5`. That function answers "what is on the calendar in the
  window I am reconciling"; this one answers "does this event still exist",
  which is a different question and must not be conflated with the first. A
  mirror mapping for a meeting three years out has a source that is alive and
  well but outside any sensible re-diff window, and reading its absence from
  that window as a deletion would tear the mirror down.

  Returns a set rather than a list because the caller's use is a membership
  test per mapping row.
  """
  @spec existing_uids(integer(), [String.t()]) :: MapSet.t(String.t())
  def existing_uids(_calendar_integration_id, []), do: MapSet.new()

  def existing_uids(calendar_integration_id, uids)
      when is_integer(calendar_integration_id) and is_list(uids) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.uid in ^uids)
    |> select([e], e.uid)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns the most recent `synced_at` among the given UIDs, or `nil` when no
  row matches.

  A cached row's `synced_at` only advances when the provider returns that event
  in a fetch, so the gap between `synced_at` and now is how long the event has
  been absent from provider responses. The CalDAV deletion circuit breaker uses
  this to distinguish a transient failed read from a calendar that has genuinely
  been emptied.
  """
  @spec max_synced_at_for_uids(integer(), [String.t()]) :: DateTime.t() | nil
  def max_synced_at_for_uids(_calendar_integration_id, []), do: nil

  def max_synced_at_for_uids(calendar_integration_id, uids) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.uid in ^uids)
    |> select([e], max(e.synced_at))
    |> Repo.one()
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
        (e.all_day == true and e.start_date <= ^range_end_date and e.end_date > ^range_start_date)
    )
  end

  defp maybe_filter_calendar_path(query, nil), do: query

  defp maybe_filter_calendar_path(query, calendar_path) do
    escaped = String.replace(calendar_path, ~r/[\\%_]/, "\\\\\\0")
    prefix = escaped <> "%"
    where(query, [e], like(e.provider_event_id, ^prefix))
  end

  @doc "Fetches a single cached event by its primary key."
  @spec fetch(integer()) ::
          {:ok, ProviderCalendarEventSchema.t()} | {:error, :not_found}
  def fetch(id) when is_integer(id) do
    case Repo.get(ProviderCalendarEventSchema, id) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @doc """
  Writes a new attendee-notification baseline for an event, updating both the
  serialised `last_notified_state` snapshot and `ical_sequence` atomically.
  """
  @spec update_notification_baseline(ProviderCalendarEventSchema.t(), map(), non_neg_integer()) ::
          {:ok, ProviderCalendarEventSchema.t()} | {:error, Changeset.t()}
  def update_notification_baseline(%ProviderCalendarEventSchema{} = event, state, sequence)
      when is_map(state) and is_integer(sequence) do
    event
    |> Changeset.change(last_notified_state: state, ical_sequence: sequence)
    |> Repo.update()
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
  Bulk-deletes events for the integration whose uid is in `uids`, chunked so a
  single statement never exceeds PostgreSQL's 65,535 bind-parameter limit.
  Returns the number of rows deleted.
  """
  @spec delete_by_uids(integer(), [String.t()]) :: non_neg_integer()
  def delete_by_uids(_calendar_integration_id, []), do: 0

  def delete_by_uids(calendar_integration_id, uids) do
    uids
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _rows} =
        ProviderCalendarEventSchema
        |> where(
          [e],
          e.calendar_integration_id == ^calendar_integration_id and e.uid in ^chunk
        )
        |> Repo.delete_all()

      acc + count
    end)
  end

  @doc """
  Bulk-deletes events for the integration whose provider_event_id is in
  `provider_event_ids`, chunked so a single statement never exceeds
  PostgreSQL's 65,535 bind-parameter limit. Returns the number of rows
  deleted.
  """
  @spec delete_by_provider_event_ids(integer(), [String.t()]) :: non_neg_integer()
  def delete_by_provider_event_ids(_calendar_integration_id, []), do: 0

  def delete_by_provider_event_ids(calendar_integration_id, provider_event_ids) do
    provider_event_ids
    |> Enum.chunk_every(@upsert_chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _rows} =
        ProviderCalendarEventSchema
        |> where(
          [e],
          e.calendar_integration_id == ^calendar_integration_id and
            e.provider_event_id in ^chunk
        )
        |> Repo.delete_all()

      acc + count
    end)
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
  Upserts a row to tag it for the offline write queue.

  Unlike `upsert_batch/1`, this helper also updates the queue-tracking
  columns (`sync_state`, `sync_attempts`, `sync_last_attempt_at`,
  `sync_last_error`) on conflict. Used exclusively by
  `CalDAV.QueueWiring.tag/3` when a local write has failed and needs
  to be replayed later — the caller's latest intent must take effect.

  Regular server-sourced upserts go through `upsert_batch/1`, which
  deliberately protects the queue-tracking columns to avoid clobbering
  pending local changes with a fresh server-view sync.

  Returns `{:ok, 1}` on success.
  """
  @spec upsert_queue_entry(map()) :: {:ok, 1}
  def upsert_queue_entry(attrs) when is_map(attrs) do
    now = DateTime.utc_now(:microsecond)

    entry =
      attrs
      |> Map.put_new(:inserted_at, now)
      |> Map.put(:updated_at, now)

    {1, _rows} =
      Repo.insert_all(
        ProviderCalendarEventSchema,
        [entry],
        on_conflict: {:replace, queue_entry_replace_fields()},
        conflict_target: [:calendar_integration_id, :uid]
      )

    {:ok, 1}
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

  # Fields updated on conflict — everything except the surrogate key,
  # inserted_at, :provider, Tymeslot-owned fields that are written independently
  # of provider data (:ical_sequence, :last_notified_state, :video_link,
  # :video_integration_id), and the offline write queue columns (:sync_state,
  # :sync_attempts, :sync_last_attempt_at, :sync_last_error) which must survive
  # a server-sourced upsert so OfflineQueue can still replay the local change
  # after the cache row has been refreshed.
  #
  # :provider_calendar_id *is* replaced, and has to be. It records which of an
  # integration's calendars the row was synced from, and `RecurringSeries` reads
  # it to fetch a series master from the calendar its instances live on — asking
  # the integration's booking calendar instead draws a 404 for an event that is
  # plainly there. Pinning it at insert meant an event moved between two
  # calendars of one integration went on naming the calendar it had left, so the
  # master fetch 404'd for as long as the series existed. That skip is a discard
  # rather than an error, so no job failed and a recurring mirror silently
  # stopped updating.
  #
  # It was held back against partial cache-update maps overwriting it with a
  # NULL EXCLUDED value. They cannot: the column is NOT NULL, so a row omitting
  # it fails at insert rather than reaching this clause, and the one partial
  # caller builds its row from the existing event's own value.
  defp replace_fields do
    [
      :provider_calendar_id,
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

  # Queue-entry upserts update the same content columns as replace_fields/0
  # PLUS the sync_state bookkeeping columns, because the caller
  # (CalDAV.QueueWiring) is declaring a new local intent and the latest
  # tag must win over any stale queue marker.
  defp queue_entry_replace_fields do
    replace_fields() ++
      [:sync_state, :sync_attempts, :sync_last_attempt_at, :sync_last_error, :created_by_tymeslot]
  end
end
