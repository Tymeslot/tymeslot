defmodule Tymeslot.DatabaseQueries.CalendarEventCacheQueries do
  @moduledoc """
  Database queries for cached calendar events.

  Provides read and write operations for the calendar_events table, which stores
  events fetched from external calendar providers keyed by (calendar_integration_id, uid).
  """

  import Ecto.Query, warn: false

  alias Tymeslot.DatabaseSchemas.CalendarEventCacheSchema
  alias Tymeslot.Repo

  @doc """
  Returns all cached events for the given integration IDs within a time range.

  Events are included if they overlap with the [start_at, end_at] window, i.e.
  the event starts before end_at and ends after start_at.
  """
  @spec list_for_range([integer()], DateTime.t(), DateTime.t()) :: [CalendarEventCacheSchema.t()]
  def list_for_range([], _start_at, _end_at), do: []

  def list_for_range(integration_ids, start_at, end_at) do
    CalendarEventCacheSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where([e], e.start_at < ^end_at and e.end_at > ^start_at)
    |> order_by([e], asc: e.start_at)
    |> Repo.all()
  end

  @doc """
  Upserts a list of event attribute maps.

  On conflict by (calendar_integration_id, uid) all mutable fields are updated.
  The `id` and `inserted_at` columns are never touched.

  Returns `{:ok, count}` on success or `{:error, reason}` on failure.
  """
  @spec upsert_batch([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def upsert_batch([]), do: {:ok, 0}

  def upsert_batch(events_attrs) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(events_attrs, fn attrs ->
        attrs
        |> Map.put_new(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _rows} =
      Repo.insert_all(
        CalendarEventCacheSchema,
        entries,
        on_conflict: {:replace, replace_fields()},
        conflict_target: [:calendar_integration_id, :uid]
      )

    {:ok, count}
  rescue
    error -> {:error, error}
  end

  @doc """
  Deletes a single event identified by its integration and uid.

  Returns `{:ok, :deleted}` if a row was removed, `{:ok, :not_found}` if nothing matched.
  """
  @spec delete_by_uid(integer(), String.t()) :: {:ok, :deleted | :not_found}
  def delete_by_uid(calendar_integration_id, uid) do
    {count, _rows} =
      CalendarEventCacheSchema
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
      CalendarEventCacheSchema
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
      CalendarEventCacheSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> Repo.delete_all()

      case upsert_batch(events_attrs) do
        {:ok, count} -> count
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Deletes cached events that ended before the given cutoff datetime.

  Returns the number of deleted rows.
  """
  @spec prune_ended_before(DateTime.t()) :: non_neg_integer()
  def prune_ended_before(cutoff) do
    {count, _rows} =
      CalendarEventCacheSchema
      |> where([e], e.end_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  @doc """
  Deletes all cached events belonging to inactive integrations.

  Returns the number of deleted rows.
  """
  @spec prune_inactive_integrations() :: non_neg_integer()
  def prune_inactive_integrations do
    {count, _rows} =
      CalendarEventCacheSchema
      |> join(:inner, [e], i in assoc(e, :calendar_integration))
      |> where([_e, i], i.is_active == false)
      |> Repo.delete_all()

    count
  end

  # Fields updated on conflict — everything except the surrogate key and inserted_at.
  defp replace_fields do
    [
      :calendar_path,
      :provider_event_id,
      :title,
      :start_at,
      :end_at,
      :all_day,
      :location,
      :description,
      :attendees,
      :recurrence_rule,
      :recurring_event_id,
      :status,
      :raw_data,
      :etag,
      :synced_at,
      :updated_at
    ]
  end
end
