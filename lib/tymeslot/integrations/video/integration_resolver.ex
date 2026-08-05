defmodule Tymeslot.Integrations.Video.IntegrationResolver do
  @moduledoc """
  Resolves which video integration can reach a meeting's provider-side room.

  A meeting normally points at the integration that created its room. That link
  is severed whenever the integration row is deleted, because the foreign key is
  `on_delete: :nilify_all` — the room keeps existing on the provider while the
  meeting loses its only reference to it.

  `meetings.video_provider` survives that deletion, so when the link is gone we
  can still fall back to whichever active integration the user currently holds
  for the same provider. That covers the disconnect-then-reconnect case, which
  is the common one: the user re-authorises Zoom and the new integration can
  delete rooms the old one created.

  The fallback deliberately does not match on the provider *account*. If the
  user reconnected a different account the delete resolves to the provider's
  not-found response, which `Tymeslot.Workers.VideoSyncWorker` already treats as
  success, so the worst case is one wasted API call rather than a wrong
  deletion.
  """

  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  @type reason :: :provider_unknown | :no_active_integration

  @doc """
  Returns the id of an integration that can reach this meeting's provider room.
  """
  @spec resolve_for_meeting(map()) :: {:ok, pos_integer()} | {:error, reason()}
  def resolve_for_meeting(%{video_integration_id: id}) when is_integer(id), do: {:ok, id}

  def resolve_for_meeting(%{organizer_user_id: nil}), do: {:error, :provider_unknown}
  def resolve_for_meeting(%{video_provider: nil}), do: {:error, :provider_unknown}

  def resolve_for_meeting(%{video_provider: provider, organizer_user_id: user_id}) do
    case VideoIntegrationQueries.get_by_provider_for_user(user_id, provider) do
      {:ok, integration} -> {:ok, integration.id}
      {:error, :not_found} -> {:error, :no_active_integration}
    end
  end
end
