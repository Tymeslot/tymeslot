defmodule Tymeslot.Integrations.Calendar.Outlook.DeltaSync do
  @moduledoc """
  Outlook (Microsoft Graph) delta-link change tracking.

  Given an integration that already has a stored `graph_delta_link`, fetches
  the changes the Graph API has accumulated since that link was issued,
  applies the changes to the local cache (upserts changed events, deletes
  removed ones, reconciles bookings), persists the new delta link returned
  by the API, and broadcasts the cache update so connected dashboards
  refresh.

  The bootstrap path (no delta link present yet) is handled by the worker
  via `OutlookCalendarAPI.bootstrap_sync/1` — this module is the steady-state
  optimisation that lets us catch up between webhook deliveries without a
  full re-sync.
  """

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Outlook.FeedCalendar
  alias Tymeslot.Integrations.Calendar.Outlook.Paging
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesMaster
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis

  # A delta link tracks the fixed window of the bootstrap that issued it, so
  # each day it covers one day less of the future. Replacing it after a week
  # keeps the cache reaching (nearly) the full window ahead.
  @rebootstrap_after_seconds 7 * 24 * 60 * 60

  @doc """
  Whether the stored delta link is old enough to be replaced by a fresh
  bootstrap. Graph fixes a delta link's window at the bootstrap that issued
  it, so without one events further ahead than that window never reach the
  cache. A link with no recorded bootstrap time (written before it was
  recorded) is due at once.
  """
  @spec rebootstrap_due?(map(), DateTime.t()) :: boolean()
  def rebootstrap_due?(integration, now \\ DateTime.utc_now())
  def rebootstrap_due?(%{last_full_sync_at: nil}, _now), do: true

  def rebootstrap_due?(%{last_full_sync_at: %DateTime{} = bootstrapped_at}, now),
    do: DateTime.diff(now, bootstrapped_at) >= @rebootstrap_after_seconds

  @doc """
  Fetches and applies Outlook delta changes for an integration that has a
  stored `graph_delta_link`. Returns `:ok` on success, or `{:error, class}` on
  any failure (already logged with context).

  `{:error, :unauthorized}` means Graph refused the stored credentials. Any
  other class distinguishes a remote that is briefly unwell (`:transient` — a
  Graph 5xx, a timeout, an open circuit) from one that needs somebody to act
  (`:hard` — bad credentials, a failed local write). The caller decides what to
  do with a job that runs out of retries; only `:transient` is safe to abandon
  to the next scheduled sweep.
  """
  @spec fetch_and_apply(map()) :: :ok | {:error, ErrorAnalysis.error_class() | :unauthorized}
  def fetch_and_apply(integration) do
    delta_link = integration.graph_delta_link

    if obsolete_delta_link?(delta_link) do
      # Older bootstraps wrote a `/me/events/delta` link whose `$deltatoken`
      # froze a ~30-day window at the moment of bootstrap and never widened.
      # Clearing the link forces the next sync to re-bootstrap via
      # `calendarView/delta`, whose window is fixed at ±365 days from that
      # bootstrap and renewed by `rebootstrap_due?/2`.
      Logger.info(
        "Outlook delta link uses obsolete /events/delta endpoint; clearing for re-bootstrap",
        calendar_integration_id: integration.id
      )

      CalendarIntegrationWebhookQueries.update_delta_link(integration, nil)
      {:error, :transient}
    else
      do_fetch_and_apply(integration, delta_link)
    end
  end

  defp do_fetch_and_apply(integration, delta_link) do
    api_module = Config.outlook_calendar_api_module()

    # Taken before the read, not after it: the events are stamped with it, and
    # reconciliation treats a Tymeslot calendar write that finished at or after
    # it as possibly missing from what was read (see
    # `Tymeslot.Meetings.ExternalCalendarChanges`). Stamped any later, a write
    # landing while the pages were still being fetched would go unnoticed.
    read_at = DateTime.utc_now(:microsecond)

    result =
      Tokens.with_access_token(integration, &api_module.refresh_token/1, fn token ->
        CalendarCircuitBreaker.call(:outlook, fn ->
          fetch_delta(token, delta_link)
        end)
      end)

    handle_fetch_result(result, integration, read_at)
  end

  defp obsolete_delta_link?(nil), do: false
  defp obsolete_delta_link?(url) when is_binary(url), do: String.contains?(url, "/events/delta")
  defp obsolete_delta_link?(_other), do: false

  defp handle_fetch_result({:ok, {:ok, events, new_delta_link}}, integration, read_at) do
    apply_delta(integration, events, new_delta_link, read_at)
  end

  # CalendarCircuitBreaker.call returns {:error, :circuit_open} when the breaker
  # is open, and {:error, reason} for errors returned by the function it wraps.
  # The {:ok, {:error, ...}} shape never occurs — errors are not wrapped in {:ok}.
  defp handle_fetch_result({:error, :circuit_open}, integration, _read_at) do
    Logger.warning("Outlook circuit breaker open during delta sync",
      calendar_integration_id: integration.id
    )

    {:error, :transient}
  end

  defp handle_fetch_result({:error, :delta_link_expired}, integration, _read_at) do
    Logger.warning("Outlook delta link expired (410); clearing stored link for re-bootstrap",
      calendar_integration_id: integration.id
    )

    CalendarIntegrationWebhookQueries.update_delta_link(integration, nil)
    {:error, :transient}
  end

  # Graph refused the stored credentials: only the owner can fix that, so it
  # is told apart from every other hard failure and the caller flags the
  # integration for reconnection rather than retrying.
  defp handle_fetch_result({:error, :unauthorized}, integration, _read_at) do
    Logger.warning("Outlook delta fetch unauthorised",
      calendar_integration_id: integration.id
    )

    {:error, :unauthorized}
  end

  # The same refusal from the token refresh `Tokens.with_access_token/4`
  # runs first: a revoked refresh token. Retrying cannot bring it back, so it
  # is flagged like the fetch's own 401 rather than retried as a hard failure.
  defp handle_fetch_result({:error, :unauthorized, _message}, integration, _read_at) do
    Logger.warning("Outlook token refresh unauthorised during delta sync",
      calendar_integration_id: integration.id
    )

    {:error, :unauthorized}
  end

  defp handle_fetch_result({:error, reason} = fetch_error, integration, _read_at) do
    Logger.warning("Outlook delta fetch failed",
      calendar_integration_id: integration.id,
      error: format_error(fetch_error)
    )

    {:error, ErrorAnalysis.classify_error(reason)}
  end

  defp handle_fetch_result(refresh_error, integration, _read_at) do
    Logger.warning("Outlook token refresh failed",
      calendar_integration_id: integration.id,
      error: format_error(refresh_error)
    )

    # Deliberately not classified: a refresh that fails is the credential path,
    # which is the case an operator most needs to hear about. Rather than let
    # the conservative "unknown means transient" default silence a revoked
    # grant, keep every refresh failure alertable.
    {:error, :hard}
  end

  defp apply_delta(integration, events, new_delta_link, read_at) do
    {removed, changed} = Enum.split_with(events, &Map.has_key?(&1, "@removed"))
    calendar_events = build_calendar_events(changed, integration, read_at)
    removed_uids = process_removed(removed, integration)

    :ok =
      SeriesRules.refresh(integration.id, calendar_events, SeriesMaster.reader(integration),
        changed: true
      )

    # Writes through `Sync.upsert_cache/2` rather than straight to the queries
    # module so this path gets ownership flagging like every other. A booking
    # Tymeslot wrote to an Outlook calendar carries a bare UUID uid, which the
    # payload-level `tymeslot_origin?/1` check cannot recognise, so without
    # this the delta sweep cached every one of them as server-owned.
    with {:ok, _count} <- Sync.upsert_cache(integration, calendar_events),
         :ok <- reconcile_and_announce(integration, calendar_events, removed_uids),
         :ok <- persist_delta_link(integration, new_delta_link) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Outlook delta upsert/persist failed during fallback sweep",
          calendar_integration_id: integration.id,
          error: reason
        )

        # Ours, not the remote's: a failed local write does not heal by waiting
        # for the next sweep, so it stays alertable.
        {:error, :hard}
    end
  end

  # The post-commit work the webhook path gets through
  # `Sync.persist_normalised_events/2`: fresh availability, the cache
  # broadcast, and the reconciliation of every linked meeting whose time
  # moved. Broadcasting alone left a booking moved in Outlook unnoticed
  # whenever this sweep saw the change first, which for an integration
  # without a Graph subscription is every time.
  #
  # It runs before the delta link is persisted: a crash in it leaves the link
  # where it was, so the next sweep receives the same changes again and
  # re-applies them (the cache upsert and the reconciliation are idempotent)
  # rather than skipping the reconciliation for good.
  #
  # The changed rows are filed under the feed's calendar first
  # (`FeedCalendar.relabel/2`), so the grids the broadcast refreshes read
  # them where they belong.
  defp reconcile_and_announce(integration, calendar_events, removed_uids) do
    FeedCalendar.relabel(integration, Enum.map(calendar_events, & &1.uid))
    Sync.post_commit_reconciliation(integration, calendar_events)
    announce_removed(integration, removed_uids)
    :ok
  end

  defp process_removed(removed, integration) do
    refs =
      for event <- removed,
          event["iCalUId"] || event["id"],
          do: %{provider_event_id: event["id"], uid: event["iCalUId"]}

    Sync.reconcile_deletions(integration, refs)

    Enum.map(refs, fn ref -> ref.uid || ref.provider_event_id end)
  end

  # `Sync.reconcile_deletions/2` has already reconciled the meetings; the
  # freed times still have to reach availability and the open grids.
  defp announce_removed(_integration, []), do: :ok

  defp announce_removed(integration, removed_uids) do
    Sync.invalidate_cache_for_user(integration)
    SyncBroadcast.broadcast_cache_update(integration.user_id, removed_uids)
  end

  # The circuit breaker wrapping this read only counts 2-tuple errors as
  # failures, so the client's {:error, type, message} shape is flattened.
  defp fetch_delta(token, delta_link) do
    case Paging.delta_all(token, {:link, delta_link}) do
      {:ok, _events, _new_delta_link} = ok -> ok
      {:error, :unauthorized, _message} -> {:error, :unauthorized}
      {:error, :delta_link_expired, _message} -> {:error, :delta_link_expired}
      {:error, type, message} -> {:error, {type, message}}
    end
  end

  defp build_calendar_events(events, integration, read_at) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: FeedCalendar.id(integration),
      synced_at: read_at
    }

    {:ok, calendar_events} = OutlookProvider.normalise_events(events, context)
    calendar_events
  end

  defp persist_delta_link(_integration, nil), do: :ok

  defp persist_delta_link(integration, new_delta_link) do
    case CalendarIntegrationWebhookQueries.update_delta_link(integration, new_delta_link) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Outlook delta link in fallback sweep",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(changeset)
        )

        {:error, :delta_link_persistence_failed}
    end
  end

  # Normalises both 2-tuple (`{:error, reason}`) and 3-tuple
  # (`{:error, type, reason}` — the `api_error()` shape returned by the
  # Outlook/Graph client) error shapes into a single printable string.
  defp format_error({:error, type, reason}) when is_atom(type),
    do: "#{type}: #{LogFormat.reason(reason)}"

  defp format_error({:error, reason}), do: LogFormat.reason(reason)

  defp format_error(other), do: LogFormat.reason(other)
end
