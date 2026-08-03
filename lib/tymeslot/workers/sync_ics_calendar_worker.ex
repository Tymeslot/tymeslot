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
  alias Tymeslot.Integrations.Calendar.Ics.Provider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck

  @calendar_id "subscription"

  @reauth_message "The calendar feed rejected the stored link. It was probably revoked or reset — subscribe again with a fresh URL."

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

      {:error, :requires_reencryption, _integration} ->
        {:discard, "Integration requires re-encryption"}
    end
  end

  defp sync(integration) do
    case Provider.fetch_feed(feed_url(integration)) do
      {:ok, raw_events} ->
        refresh_cache(integration, raw_events)

      {:error, :unauthorised} ->
        flag_reauth_required(integration)

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

  defp flag_reauth_required(integration) do
    Logger.warning("Calendar subscription feed rejected the stored link; flagging for reauth",
      calendar_integration_id: integration.id
    )

    case CalendarManagement.mark_needs_reauth(integration, @reauth_message) do
      {:ok, _updated} ->
        {:discard, "Calendar feed rejected the stored link — a fresh URL is required"}

      {:error, _changeset} ->
        {:error, "Failed to flag subscription for reauth"}
    end
  end

  defp record_failure(integration, reason) do
    Logger.error("Calendar subscription sync failed",
      calendar_integration_id: integration.id,
      error: inspect(reason)
    )

    CalendarIntegrationQueries.mark_sync_error(integration, failure_message(reason))

    {:error, reason}
  end

  defp failure_message(:not_found), do: "The calendar feed URL returned 404. Check the link."

  defp failure_message(:invalid_ics),
    do: "The calendar feed did not return valid iCalendar data."

  defp failure_message(:too_large), do: "The calendar feed is too large to process."

  defp failure_message(:too_many_redirects),
    do: "The calendar feed redirected too many times."

  defp failure_message({:blocked, _reason}),
    do: "The calendar feed URL points at a blocked address."

  defp failure_message({:http_status, status}),
    do: "The calendar feed returned HTTP #{status}."

  defp failure_message(_reason), do: "Could not reach the calendar feed."

  defp feed_url(%{subscription_url: url}) when is_binary(url), do: url
  defp feed_url(_integration), do: nil
end
