defmodule Tymeslot.CalendarGrid.Freshness do
  @moduledoc """
  How fresh the calendar grid's cached events are, and the refresh that
  brings them up to date: which integrations are stale, and enqueueing a
  sync of one of them.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationRefQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.SyncSchedule

  @doc """
  Asks for a sync of one of the user's active integrations, through
  `SyncSchedule`, which names the worker its provider uses. `how` is
  `:requested` for Sync now or Retry, which brings forward even a sync
  waiting out an error's backoff, or `:opened` for the sync the calendar
  asks for by itself when it opens on stale events, which leaves such a
  sync to its backoff and answers `:backing_off`.
  `{:error, :not_found}` for an integration that is not the user's, or not
  active.
  """
  @spec request_sync(integer(), integer(), :requested | :opened) ::
          :ok | :backing_off | {:error, term()}
  def request_sync(user_id, integration_id, how \\ :requested) do
    case CalendarIntegrationRefQueries.get_active(user_id, integration_id) do
      nil ->
        {:error, :not_found}

      integration ->
        case request(integration, how) do
          {:ok, :backing_off} -> :backing_off
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Returns integrations whose cached data is stale: never synced, or synced
  longer ago than their provider's stale threshold (`SyncSchedule`). An
  Outlook integration still waiting for its first sync is pending, not
  stale.
  """
  @spec stale_integrations([CalendarIntegrationSchema.t()]) :: [CalendarIntegrationSchema.t()]
  def stale_integrations(integrations) do
    now = Clock.utc_now()
    Enum.filter(integrations, &stale?(&1, now))
  end

  # Private

  defp request(integration, :requested), do: SyncSchedule.request_sync(integration)

  defp request(integration, :opened),
    do: SyncSchedule.request_sync_unless_backing_off(integration)

  # Outlook pending initial setup: subscription registration hasn't succeeded yet
  # (e.g. WEBHOOK_BASE_URL not configured). This is "pending", not "stale" —
  # showing a stale banner the user can't resolve is just noise.
  defp stale?(%{provider: "outlook", graph_delta_link: nil, last_external_sync_at: nil}, _now),
    do: false

  defp stale?(%{last_external_sync_at: nil}, _now), do: true

  defp stale?(integration, now), do: SyncSchedule.stale?(integration, now)
end
