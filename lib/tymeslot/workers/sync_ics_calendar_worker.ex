defmodule Tymeslot.Workers.SyncIcsCalendarWorker do
  @moduledoc """
  Oban worker that refreshes a subscribed calendar feed into the local event
  cache.

  A published feed has no delta mechanism: no sync token, no CTag, no
  per-event ETags worth trusting. Every run therefore fetches the whole file
  and replaces the integration's cached events in one transaction
  (`ProviderCalendarEventQueries.full_refresh_for_integration/2`), which is
  also what makes deletions visible — an event that has vanished from the
  feed simply isn't in the replacement set.

  This is the only place the feed URL is fetched. The provider's own read
  path serves this cache, so the freshness of every availability check is
  bounded by how often this worker runs rather than by the publisher's
  response time. See `Tymeslot.Integrations.Calendar.Ics.Provider` for why.

  A 401 or 403 means the feed URL has been revoked or rotated, which no
  amount of retrying will fix: the integration is flagged `needs_reauth` and
  the job discarded so the user is prompted to paste a fresh link. Everything
  else records a sync error and retries.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Ics.Feed
  alias Tymeslot.Integrations.Calendar.Ics.Provider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck

  @calendar_id "subscription"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}}) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        sync(integration)

      {:error, :not_found} ->
        Logger.warning("Calendar subscription not found, discarding sync job",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
    end
  end

  defp sync(integration) do
    case Provider.fetch_feed(feed_url(integration)) do
      {:ok, raw_events} ->
        refresh_cache(integration, raw_events)

      {:error, :unauthorised} ->
        CalendarManagement.handle_reauth_required(integration, cause: :rejected_subscription_url)

      {:error, :missing_url} ->
        Logger.error("Calendar subscription has no feed URL stored",
          calendar_integration_id: integration.id
        )

        {:discard, "Subscription has no feed URL"}

      {:error, reason} ->
        record_failure(integration, reason)
    end
  end

  defp refresh_cache(integration, raw_events) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: @calendar_id,
      synced_at: DateTime.utc_now()
    }

    {:ok, events} = Provider.normalise_events(raw_events, context)

    if events == [] and cache_populated?(integration) do
      record_failure(integration, :empty_feed_with_populated_cache)
    else
      write_cache(integration, events)
    end
  end

  # A syntactically valid but empty feed is far more likely a bad read than a
  # genuinely emptied calendar once the cache already holds events for this
  # integration — see the moduledoc. Wiping on that signal alone is the one
  # non-self-healing damage path in this worker, so it is refused: the cache
  # is left as-is and the job retries.
  defp cache_populated?(integration) do
    now = DateTime.utc_now()
    range_start = DateTime.add(now, -ProviderConfig.sync_window_past_days(), :day)
    range_end = DateTime.add(now, ProviderConfig.sync_window_future_days(), :day)

    [integration.id]
    |> ProviderCalendarEventQueries.list_for_range(range_start, range_end, limit: 1)
    |> Enum.any?()
  end

  defp write_cache(integration, events) do
    attrs = Enum.map(events, &ProviderCalendarEventSchema.from_calendar_event/1)

    case ProviderCalendarEventQueries.full_refresh_for_integration(integration.id, attrs) do
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

      {:error, reason} ->
        record_failure(integration, reason)
    end
  rescue
    error -> record_failure(integration, error)
  end

  # Stamps its own timestamps rather than going through
  # `CalendarIntegrationQueries.mark_sync_success/1`: every real sync worker
  # does the same, and a feed refresh is always a full one, so
  # `last_full_sync_at` moves with the rest.
  defp mark_synced(integration, count) do
    now = DateTime.utc_now(:second)

    attrs = %{
      last_sync_at: now,
      last_external_sync_at: now,
      last_full_sync_at: now,
      sync_error: nil,
      needs_reauth: false
    }

    case CalendarIntegrationQueries.update_sync_state(integration, attrs) do
      {:ok, _updated} ->
        HealthCheck.mark_synced_successfully(:calendar, integration.id)

        Logger.info("Calendar subscription refreshed",
          calendar_integration_id: integration.id,
          event_count: count
        )

        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist calendar subscription sync state",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        :ok
    end
  end

  defp record_failure(integration, reason) do
    Logger.error("Calendar subscription sync failed",
      calendar_integration_id: integration.id,
      error: inspect(reason)
    )

    CalendarIntegrationQueries.mark_sync_error(integration, error_message(reason))

    {:error, reason}
  end

  # A rescued exception never reaches `Feed.error_message/1` — it only knows
  # the feed-fetch vocabulary — so it gets its own message naming the failure
  # class instead, and the guarded empty-feed case gets one of its own too.
  defp error_message(exception) when is_exception(exception) do
    "Calendar subscription sync failed while writing a fetched event to the cache " <>
      "(#{inspect(exception.__struct__)}): #{Exception.message(exception)}"
  end

  defp error_message(:empty_feed_with_populated_cache) do
    "The calendar feed came back empty, but the cache still holds previously synced events. " <>
      "Keeping the cache in place and retrying rather than emptying your diary."
  end

  defp error_message(reason) do
    Feed.error_message(reason)
  end

  defp feed_url(%{subscription_url: url}) when is_binary(url), do: url
  defp feed_url(_integration), do: nil
end
