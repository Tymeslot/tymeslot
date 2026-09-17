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

  Which rooms go depends on the provider (`room_scope/1`). The modal that asks
  the question and the worker that acts on the answer both choose through it.
  The rooms are those of bookings and those made for events on the dashboard
  calendar grid (`Tymeslot.CalendarGrid.EventVideoRooms`).
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Meetings.MeetingQueries
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

  @doc """
  Which of an integration's rooms deleting them on disconnect covers.

  Most providers' rooms expire on their own, so only upcoming bookings' rooms
  are worth deleting. A provider whose rooms stay on the organiser's server
  until something deletes them (`ProviderConfig.rooms_deleted_after_meeting/0`)
  has every room it still holds deleted, ended and cancelled meetings included,
  because once the row is purged nothing has the credentials to reach them.
  """
  @spec room_scope(String.t()) :: MeetingListQueries.room_scope()
  def room_scope(provider) do
    if provider in ProviderConfig.rooms_deleted_after_meeting(), do: :all, else: :upcoming
  end

  @doc """
  The rooms disconnecting the user's integration with `delete_rooms: true`
  would delete: their scope and how many there are.

  The count is zero when there is nothing such a disconnect could delete: the
  integration is not the user's, or its credentials cannot be read, in which
  case `run/3` drops the row without touching any room.
  """
  @spec rooms_to_delete(pos_integer(), pos_integer()) :: %{
          scope: MeetingListQueries.room_scope(),
          count: non_neg_integer()
        }
  def rooms_to_delete(user_id, id) when is_integer(user_id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} ->
        scope = room_scope(integration.provider)
        now = DateTime.utc_now()

        %{
          scope: scope,
          count:
            MeetingQueries.count_with_video_room_for_integration(integration.id, scope, now) +
              CalendarGrid.count_event_video_rooms_for_integration(integration.id, scope, now)
        }

      {:error, :not_found} ->
        %{scope: :upcoming, count: 0}

      {:error, :requires_reencryption, integration} ->
        %{scope: room_scope(integration.provider), count: 0}
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
