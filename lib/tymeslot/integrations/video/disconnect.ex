defmodule Tymeslot.Integrations.Video.Disconnect do
  @moduledoc """
  Removes a video integration, optionally deleting its provider-side rooms first.

  Disconnecting is two different operations wearing one name. On its own it just
  drops the row: the rooms of upcoming bookings carry on working, because their
  join URLs are already sitting in attendees' calendar invites and deleting them
  would break meetings that are still going ahead.

  With `delete_rooms: true` the user has asked for those rooms to go too. That
  needs the OAuth credentials stored on the row being removed, and the provider
  calls run in a background job, so the row is soft-deleted rather than dropped:
  hidden from every user-facing read, retained just long enough for
  `Tymeslot.Workers.VideoIntegrationDisconnectWorker` to use it, then purged.
  """

  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker

  require Logger

  @doc """
  Disconnects the integration, honouring the `:delete_rooms` option.
  """
  @spec run(pos_integer(), pos_integer(), keyword()) ::
          {:ok, :deleted | :cleanup_scheduled} | {:error, any()}
  def run(user_id, id, opts) when is_integer(user_id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} ->
        remove(integration, Keyword.get(opts, :delete_rooms, false))

      {:error, :not_found} = err ->
        err

      {:error, :requires_reencryption, integration} ->
        # The credentials cannot be decrypted, so no provider call could succeed.
        # Drop the row regardless of what was asked for.
        remove(integration, false)
    end
  end

  @spec remove(VideoIntegrationSchema.t(), boolean()) ::
          {:ok, :deleted | :cleanup_scheduled} | {:error, any()}
  defp remove(integration, false) do
    case VideoIntegrationQueries.delete(integration) do
      {:ok, _result} -> {:ok, :deleted}
      {:error, _reason} = err -> err
    end
  end

  defp remove(integration, true) do
    with {:ok, soft} <- VideoIntegrationQueries.soft_delete(integration),
         {:ok, _status} <- VideoIntegrationDisconnectWorker.enqueue(soft.id) do
      {:ok, :cleanup_scheduled}
    else
      {:error, reason} ->
        # Better to complete the disconnect the user asked for than to leave a
        # hidden row behind with nothing scheduled to clean it up.
        Logger.warning("Failed to schedule video room cleanup, removing integration directly",
          integration_id: integration.id,
          reason: inspect(reason)
        )

        remove(integration, false)
    end
  end
end
