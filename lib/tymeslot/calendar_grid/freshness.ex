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

  Each integration's sync is asked for through `SyncSchedule`, which names
  the worker its provider uses; one whose provider has no schedule is
  reported in `:errors`.

  `how` is `:requested` for the owner's Refresh (`SyncSchedule.request_sync/1`),
  which brings forward even a sync waiting out an error's backoff, or
  `:opened` for the refresh the grid starts by itself when opened on stale
  events (`SyncSchedule.request_sync_unless_backing_off/1`), which leaves
  such a sync to its backoff and counts it in `:skipped`.

  Returns `{:ok, %{enqueued: count, skipped: count, errors: [{integration_id, reason}]}}`.
  """
  @spec refresh_events(integer(), :requested | :opened) ::
          {:ok,
           %{
             enqueued: non_neg_integer(),
             skipped: non_neg_integer(),
             errors: [{integer(), term()}]
           }}
  def refresh_events(user_id, how \\ :requested) do
    # The context call decrypts credentials; acceptable overhead for a
    # user-initiated refresh since we need id + provider for each integration.
    integrations = Management.list_active_calendar_integrations(user_id)

    {enqueued, skipped, errors} =
      Enum.reduce(integrations, {0, 0, []}, fn integration, {count, skip, errs} ->
        case request(integration, how) do
          {:ok, :backing_off} -> {count, skip + 1, errs}
          {:ok, _job} -> {count + 1, skip, errs}
          {:error, reason} -> {count, skip, [{integration.id, reason} | errs]}
        end
      end)

    {:ok, %{enqueued: enqueued, skipped: skipped, errors: errors}}
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
