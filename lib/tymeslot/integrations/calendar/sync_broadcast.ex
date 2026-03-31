defmodule Tymeslot.Integrations.Calendar.SyncBroadcast do
  @moduledoc """
  PubSub helpers for broadcasting calendar cache updates to connected grids.

  Also provides cache+broadcast coordination helpers used by calendar sync
  workers to upsert events and notify subscribers in a single call.
  """

  alias Tymeslot.DatabaseQueries.CalendarEventCacheQueries

  require Logger

  @doc """
  Upserts a calendar event to the cache and broadcasts the update.
  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec upsert_and_broadcast(integer(), map()) :: :ok | {:error, any()}
  def upsert_and_broadcast(user_id, attrs) do
    CalendarEventCacheQueries.upsert_batch([attrs])
    broadcast_cache_update(user_id, [attrs.uid])
    :ok
  rescue
    e ->
      Logger.warning("Cache upsert failed, skipping broadcast",
        user_id: user_id,
        uid: attrs[:uid],
        reason: Exception.message(e)
      )

      {:error, e}
  end

  @doc """
  Upserts an event to the cache, broadcasts the update, and calls `on_success` if the upsert succeeded.
  On failure, logs a warning with the given `log_context`.
  """
  @spec process_cached_event(integer(), map(), keyword(), (-> any())) :: :ok | {:error, any()}
  def process_cached_event(user_id, attrs, _log_context, on_success) do
    case upsert_and_broadcast(user_id, attrs) do
      :ok ->
        on_success.()

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Broadcasts a cache update for the given user and list of UIDs.
  """
  @spec broadcast_cache_update(integer(), [String.t()]) :: :ok
  def broadcast_cache_update(user_id, uids) do
    do_broadcast(user_id, {:calendar_events_updated, user_id, uids})
  end

  @doc """
  Broadcasts that a single integration has completed its sync cycle.
  Sent once per integration after `persist_sync_state` commits, so the UI can
  update its progress counter and reload integration timestamps when all are done.
  """
  @spec broadcast_sync_complete(integer(), integer()) :: :ok
  def broadcast_sync_complete(user_id, integration_id) do
    do_broadcast(user_id, {:calendar_sync_complete, user_id, integration_id})
  end

  defp do_broadcast(user_id, message) do
    case Phoenix.PubSub.broadcast(Tymeslot.PubSub, "calendar_events:#{user_id}", message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("PubSub broadcast failed", reason: inspect(reason), user_id: user_id)
        :ok
    end
  end
end
