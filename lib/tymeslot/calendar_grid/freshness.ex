defmodule Tymeslot.CalendarGrid.Freshness do
  @moduledoc """
  How fresh the calendar grid's cached events are, and the refresh that
  brings them up to date: which integrations are stale, the oldest sync
  among them, and enqueueing a sync of every active integration.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.SyncSchedule

  @doc """
  Enqueues sync workers for all active integrations belonging to the user.

  Each integration's sync is asked for through `SyncSchedule.request_sync/1`,
  which names the worker its provider uses; one whose provider has no
  schedule is reported in `:errors`.

  Returns `{:ok, %{enqueued: count, errors: [{integration_id, reason}]}}`.
  """
  @spec refresh_events(integer()) ::
          {:ok,
           %{
             enqueued: non_neg_integer(),
             skipped: non_neg_integer(),
             errors: [{integer(), term()}]
           }}
  def refresh_events(user_id) do
    # The context call decrypts credentials; acceptable overhead for a
    # user-initiated refresh since we need id + provider for each integration.
    integrations = Management.list_active_calendar_integrations(user_id)

    {enqueued, skipped, errors} =
      Enum.reduce(integrations, {0, 0, []}, fn integration, {count, skip, errs} ->
        case SyncSchedule.request_sync(integration) do
          {:ok, _job} -> {count + 1, skip, errs}
          {:error, reason} -> {count, skip, [{integration.id, reason} | errs]}
        end
      end)

    {:ok, %{enqueued: enqueued, skipped: skipped, errors: errors}}
  end

  @doc """
  Asks for a sync of one of the user's active integrations, as Refresh does
  for all of them. `{:error, :not_found}` for an integration that is not
  the user's, or not active.
  """
  @spec request_sync(integer(), integer()) :: :ok | {:error, term()}
  def request_sync(user_id, integration_id) do
    integrations = Management.list_active_calendar_integrations(user_id)

    case Enum.find(integrations, &(&1.id == integration_id)) do
      nil ->
        {:error, :not_found}

      integration ->
        case SyncSchedule.request_sync(integration) do
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

  @doc """
  Returns the oldest `last_external_sync_at` across the given integrations,
  or nil when none have synced.
  """
  @spec oldest_sync_at([CalendarIntegrationSchema.t()]) :: DateTime.t() | nil
  def oldest_sync_at([]), do: nil

  def oldest_sync_at(integrations) do
    timestamps =
      integrations
      |> Enum.map(& &1.last_external_sync_at)
      |> Enum.reject(&is_nil/1)

    if timestamps == [], do: nil, else: Enum.min(timestamps, DateTime)
  end

  # Private

  # Outlook pending initial setup: subscription registration hasn't succeeded yet
  # (e.g. WEBHOOK_BASE_URL not configured). This is "pending", not "stale" —
  # showing a stale banner the user can't resolve is just noise.
  defp stale?(%{provider: "outlook", graph_delta_link: nil, last_external_sync_at: nil}, _now),
    do: false

  defp stale?(%{last_external_sync_at: nil}, _now), do: true

  defp stale?(integration, now), do: SyncSchedule.stale?(integration, now)
end
