defmodule Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler do
  @moduledoc """
  Deletion reconciliation and event processing for CalDAV sync workers.

  Handles three concerns that sit between raw CalDAV protocol operations and
  the provider-agnostic `Sync` module:

  1. **Safe event processing** — normalises raw CalDAV events, persists them
     via `Sync.persist_normalised_events/2`, and processes any deletion hrefs
     from a Tier 1 sync-collection response.

  2. **Href-based deletions** (Tier 1) — processes explicit deletion signals
     from sync-collection responses where the server reports removed resources
     by href.

  3. **UID-based deletion detection** (Tier 2/3 full fetch) — compares
     fetched event UIDs against the local cache to identify events that have
     disappeared from the server within the sync time window.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync

  @doc """
  Normalises, persists, and reconciles a batch of CalDAV events.

  Optionally processes a list of `deleted_hrefs` from a Tier 1
  sync-collection response. Returns `:ok` on success or
  `{:error, reason}` if normalisation or persistence fails.
  """
  @spec safe_process_events(map(), list(map()), list(String.t())) :: :ok | {:error, term()}
  def safe_process_events(integration, events, deleted_hrefs \\ []) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: List.first(integration.calendar_paths),
      synced_at: DateTime.utc_now(:microsecond)
    }

    with {:ok, calendar_events} <- CalDAVProvider.normalise_events(events, context),
         :ok <- Sync.persist_normalised_events(integration, calendar_events) do
      process_href_deletions(integration, deleted_hrefs)
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  @doc """
  Detects events that have been deleted from the server by comparing
  fetched UIDs against the local cache.

  Used after a full fetch (Tier 2 CTag change or Tier 3) to find events
  present in the cache but absent from the server response within the
  sync time window.
  """
  @spec detect_deletions(map(), list(map()), DateTime.t(), DateTime.t(), DateTime.t(), String.t()) ::
          :ok
  def detect_deletions(
        integration,
        fetched_events,
        start_time,
        end_time,
        sync_started_at,
        calendar_path
      ) do
    fetched_uids = MapSet.new(fetched_events, &Map.get(&1, :uid))

    cached_uids =
      ProviderCalendarEventQueries.list_uids_in_range(
        integration.id,
        start_time,
        end_time,
        sync_started_at,
        calendar_path
      )

    missing_uids = Enum.reject(cached_uids, &MapSet.member?(fetched_uids, &1))

    if missing_uids != [] do
      Logger.info("CalDAV full fetch detected missing events",
        calendar_integration_id: integration.id,
        missing_count: length(missing_uids)
      )

      Enum.each(missing_uids, fn uid ->
        ProviderCalendarEventQueries.delete_by_uid(integration.id, uid)

        case Sync.reconcile(integration.id, nil, uid, :deleted) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Reconcile failed for deleted event",
              uid: uid,
              integration_id: integration.id,
              reason: inspect(reason)
            )
        end
      end)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp process_href_deletions(_integration, []), do: :ok

  defp process_href_deletions(integration, deleted_hrefs) do
    Enum.each(deleted_hrefs, fn href ->
      ProviderCalendarEventQueries.delete_by_provider_event_id(integration.id, href)

      case Sync.reconcile(integration.id, href, nil, :deleted) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Reconcile failed for deleted event",
            href: href,
            integration_id: integration.id,
            reason: inspect(reason)
          )
      end
    end)
  end
end
