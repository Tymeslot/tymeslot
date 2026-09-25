defmodule Tymeslot.Integrations.Video.Reconnect do
  @moduledoc """
  Saves credentials proven to work, and catches the integration's rooms up on
  what they missed while it needed reconnecting.

  While an integration is flagged for reconnection, changes to its bookings
  cannot reach the provider: a reschedule or a cancellation is refused and its
  job discarded, and nothing sends it again later. A room then keeps the old
  time and name, or outlives a booking that was released. So when a proven
  reconnect clears the flag, every upcoming meeting holding one of the
  integration's rooms is queued once more: an update for a live booking, a
  delete for a released one (`Tymeslot.Meetings.MeetingState.released_status?/1`).
  Both are idempotent, so queueing rooms that missed nothing is harmless.

  Only a proof counts: an OAuth callback, or a credential change the provider
  accepted. A flag cleared without one must not queue anything, because those
  jobs would go out with credentials that may still be refused, and on a
  self-hosted server each refusal counts against its brute-force protection.
  Only providers whose rooms hold the booking's time or name are caught up
  (`ProviderConfig.rooms_updated_on_reschedule?/1`); every other provider's
  room is a link with nothing to update or delete.
  """

  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Workers.VideoSyncWorker

  require Logger

  # How many upcoming meetings one reconnect catches up, far more than one
  # integration holds in practice.
  @room_limit 500

  @doc """
  Saves `attrs` on `integration` as credentials proven to work, clearing its
  reconnect flag, and catches its rooms up when the row was flagged as it was
  written.
  """
  @spec save(VideoIntegrationSchema.t(), map()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def save(%VideoIntegrationSchema{} = integration, attrs) do
    case VideoIntegrationQueries.reconnect(integration, attrs) do
      {:ok, updated, was_flagged?} ->
        if was_flagged?, do: catch_up_rooms(updated)
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  # Runs after the write has committed, so every job reads the reconnected
  # integration.
  defp catch_up_rooms(%VideoIntegrationSchema{id: id, provider: provider}) do
    if ProviderConfig.rooms_updated_on_reschedule?(provider) do
      rooms =
        MeetingListQueries.list_upcoming_video_rooms_for_integration(
          id,
          DateTime.utc_now(),
          @room_limit
        )

      warn_when_capped(rooms, id)
      Enum.each(rooms, &enqueue(&1, id))
    end

    :ok
  end

  defp warn_when_capped(rooms, integration_id) when length(rooms) >= @room_limit do
    Logger.warning("Reconnect caught up only the first rooms of an integration",
      integration_id: integration_id,
      limit: @room_limit
    )
  end

  defp warn_when_capped(_rooms, _integration_id), do: :ok

  defp enqueue(%{id: meeting_id, status: status}, integration_id) do
    action = if MeetingState.released_status?(status), do: "delete", else: "update"

    case VideoSyncWorker.enqueue(meeting_id, action) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to queue a room sync after the integration was reconnected",
          meeting_id: meeting_id,
          integration_id: integration_id,
          action: action,
          reason: inspect(reason)
        )
    end
  end
end
