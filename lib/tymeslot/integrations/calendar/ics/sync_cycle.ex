defmodule Tymeslot.Integrations.Calendar.Ics.SyncCycle do
  @moduledoc """
  One refresh of a subscribed calendar feed into the local event cache, with
  no knowledge of the job running it.

  A published feed has no delta mechanism: no sync token, no CTag, no
  per-event ETags worth trusting. Every run therefore fetches the whole file
  and replaces the integration's cached events in one transaction
  (`IntegrationCacheQueries.replace_cached_rows/3`), which is
  also what makes deletions visible: an event that has vanished from the
  feed simply isn't in the replacement set.

  This is the only place the feed URL is fetched. The provider's own read
  path serves this cache, so the freshness of every availability check is
  bounded by how often a refresh runs rather than by the publisher's
  response time. See `Tymeslot.Integrations.Calendar.Ics.Provider` for why.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Ics.Provider
  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  @calendar_id "subscription"

  @doc """
  Refreshes the subscription `integration` from its feed.

  Returns `:ok`, or `{:error, reason}`: `:unauthorised` for a feed URL the
  publisher revoked, `:missing_url` for a subscription with none stored,
  `:empty_feed_with_populated_cache` for an empty feed refused over a
  populated cache, or a fetch or write failure. Nothing is recorded against
  the integration on a failure: what a failure means is the caller's.
  """
  @spec run(CalendarIntegrationSchema.t()) :: :ok | {:error, term()}
  def run(%CalendarIntegrationSchema{} = integration) do
    with {:ok, raw_events} <- Provider.fetch_feed(feed_url(integration)) do
      refresh_cache(integration, raw_events)
    end
  end

  defp refresh_cache(integration, raw_events) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: @calendar_id,
      synced_at: DateTime.utc_now()
    }

    {:ok, events} = Provider.normalise_events(raw_events, context)

    # Every row a feed writes is `both`: a feed has no busy-only read and,
    # being read-only, no locally deleted rows, so the guard counts exactly
    # the rows this refresh would replace.
    case Sync.refuse_empty_over_populated(integration, EventRole.both(), events, Sync.window()) do
      :ok -> write_cache(integration, events)
      {:error, _reason} = error -> error
    end
  end

  defp write_cache(integration, events) do
    attrs = Enum.map(events, &ProviderCalendarEventSchema.from_calendar_event/1)

    case IntegrationCacheQueries.replace_cached_rows(integration.id, :all, attrs) do
      {:ok, count} ->
        # Deliberately not `Sync.post_commit_reconciliation/2`: that also
        # rewrites linked meetings whose times moved externally, which a
        # read-only mirror of someone else's calendar has no business doing.
        # The cache invalidation and grid broadcast are still wanted.
        Sync.invalidate_cache_for_user(integration)
        SyncBroadcast.broadcast_cache_update(integration.user_id, Enum.map(events, & &1.uid))

        mark_synced(integration, count)
        SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
        :ok

      {:error, _reason} = error ->
        error
    end
  rescue
    error -> {:error, error}
  end

  # A feed refresh is always a full one, so `last_full_sync_at` moves with the
  # per-cycle marker rather than lagging behind it. Clearing `sync_error` and
  # `needs_reauth` belongs to every provider's successful cycle alike, so
  # `SyncHealth.record_outcome/2` owns that at the job boundary.
  defp mark_synced(integration, count) do
    now = DateTime.utc_now(:second)

    attrs = %{
      last_external_sync_at: now,
      last_full_sync_at: now
    }

    case CalendarIntegrationQueries.update_sync_state(integration, attrs) do
      {:ok, _updated} ->
        Logger.info("Calendar subscription refreshed",
          calendar_integration_id: integration.id,
          event_count: count
        )

        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist calendar subscription sync state",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(changeset)
        )

        :ok
    end
  end

  defp feed_url(%{subscription_url: url}) when is_binary(url), do: url
  defp feed_url(_integration), do: nil
end
