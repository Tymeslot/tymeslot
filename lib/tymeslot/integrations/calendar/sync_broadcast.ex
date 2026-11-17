defmodule Tymeslot.Integrations.Calendar.SyncBroadcast do
  @moduledoc """
  PubSub helpers for broadcasting calendar cache updates to connected grids.
  """

  require Logger

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

  @doc """
  Broadcasts that an integration's sync cycle failed or was discarded, so a
  calendar showing it as syncing stops and can say what that means.
  """
  @spec broadcast_sync_failed(integer(), integer()) :: :ok
  def broadcast_sync_failed(user_id, integration_id) do
    do_broadcast(user_id, {:calendar_sync_failed, user_id, integration_id})
  end

  @doc """
  Broadcasts how a delete scheduled from the calendar ended (see
  `Tymeslot.CalendarGrid.ScheduledDelete`): `token` names the delete,
  `outcome` is `:deleted`, `{:queued, reason}` or `{:failed, reason}`.
  """
  @spec broadcast_delete_result(integer(), pos_integer(), term()) :: :ok
  def broadcast_delete_result(user_id, token, outcome) do
    do_broadcast(user_id, {:calendar_delete_result, user_id, token, outcome})
  end

  @doc """
  Broadcasts that a delete was scheduled from the calendar, with the address
  it was scheduled with, so the organiser's other calendars hide the event.
  """
  @spec broadcast_delete_scheduled(integer(), pos_integer(), map(), atom()) :: :ok
  def broadcast_delete_scheduled(user_id, token, address, scope) do
    do_broadcast(user_id, {:calendar_delete_scheduled, user_id, token, address, scope})
  end

  @doc "Broadcasts that Undo cancelled the scheduled delete `token`."
  @spec broadcast_delete_cancelled(integer(), pos_integer()) :: :ok
  def broadcast_delete_cancelled(user_id, token) do
    do_broadcast(user_id, {:calendar_delete_cancelled, user_id, token})
  end

  defp do_broadcast(user_id, message) do
    case Phoenix.PubSub.broadcast(Tymeslot.PubSub, "calendar_events:#{user_id}", message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("PubSub broadcast failed", reason: reason, user_id: user_id)
        :ok
    end
  end
end
