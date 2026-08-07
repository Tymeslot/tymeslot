defmodule Tymeslot.Integrations.Calendar.CalDAV.Sync.State do
  @moduledoc """
  Persistence of a CalDAV integration's sync bookkeeping.

  Three columns record where a sync got to: `caldav_sync_token` (a
  `DAV:sync-token` on Tier 1, a `getctag` value on Tier 2),
  `caldav_sync_tier`, and the `last_external_sync_at` / `last_full_sync_at`
  timestamps.

  Every write here is best-effort. Losing a bookkeeping write costs at most one
  redundant full fetch on the next cycle, whereas failing the job would discard
  event data that has already been reconciled into the database. So a failed
  update logs and reports success; only the *event* write path can fail a sync.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck

  @doc """
  Records the detected sync tier and returns the updated integration.

  Tier detection is one-shot, so the caller needs the updated struct to sync
  with in the same run. If the write fails the tier is still applied in memory:
  the detection already happened and re-probing within the same run would be
  wasted work.
  """
  @spec put_tier(struct(), pos_integer()) :: struct()
  def put_tier(integration, tier) do
    case CalendarIntegrationQueries.update_sync_state(integration, %{caldav_sync_tier: tier}) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning("Failed to persist CalDAV sync tier",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        %{integration | caldav_sync_tier: tier}
    end
  end

  @doc """
  Stamps the sync as having completed, optionally updating tracking columns.

  `last_external_sync_at` is always refreshed. The recognised options are
  `:sync_token`, `:last_full_sync_at` and `:sync_tier`; an option that is
  absent leaves its column untouched, which is how a Tier 1 failure keeps the
  previous sync token rather than advancing past changes it never applied.
  """
  @spec put(struct(), keyword()) :: :ok
  def put(integration, opts) do
    attrs =
      %{last_external_sync_at: DateTime.utc_now(:second)}
      |> maybe_put(opts, :sync_token, :caldav_sync_token)
      |> maybe_put(opts, :last_full_sync_at, :last_full_sync_at)
      |> maybe_put(opts, :sync_tier, :caldav_sync_tier)

    result = CalendarIntegrationQueries.update_sync_state(integration, attrs)
    HealthCheck.mark_synced_successfully(:calendar, integration.id)

    case result do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist CalDAV sync state",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        :ok
    end
  end

  defp maybe_put(attrs, opts, opt_key, attr_key) do
    case Keyword.fetch(opts, opt_key) do
      {:ok, value} -> Map.put(attrs, attr_key, value)
      :error -> attrs
    end
  end
end
