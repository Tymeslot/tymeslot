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
