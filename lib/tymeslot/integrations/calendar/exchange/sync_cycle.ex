defmodule Tymeslot.Integrations.Calendar.Exchange.SyncCycle do
  @moduledoc """
  One sync cycle of an Exchange mailbox into the local event cache, with no
  knowledge of the job running it.

  ## Two reads, two halves of the cache

  EWS answers the two questions this product asks with two different
  operations, and neither subsumes the other (see
  `Tymeslot.Integrations.Calendar.Exchange.Provider`):

    * `GetUserAvailability` says **when the mailbox is busy**, with recurring
      series expanded server-side. Its intervals carry no identity at all, so
      they are stored under a synthesised uid as `busy_only` rows and are the
      only Exchange rows that block a slot.
    * `FindItem` + a batched `GetItem` say **what each event is**: subject,
      location, change key. Those become `display_only` rows, which the
      dashboard grid renders and which block nothing, because a recurring
      master's dates describe only its own first occurrence and would free up
      every later one.

  Both are reached through the provider's explicitly-named live reads,
  `Provider.list_busy_intervals/2` and `Provider.list_calendar_items/2`. This
  cycle is their only caller: `Provider.list_events/2` is the availability
  callback and reads the cache these two write, so calling it from here would
  have a sync re-persist whatever the last sync left behind.

  Both halves belong to the same integration, so each is replaced through
  `Calendar.Sync.full_refresh_for_role/3` rather than the unscoped full
  refresh: that one deletes *every* row an integration holds, which would have
  each half wipe the other's on every cycle.

  The availability read runs first and its failure ends the run without
  writing anything. The item read failing afterwards costs the grid its
  freshness and nothing more, which is the right way round: the busy rows are
  already written and correct.

  That later failure still ends the run, though, and deliberately: `sync/1`
  short-circuits, so the busy rows stay written but the availability cache is
  *not* invalidated and `last_external_sync_at` does *not* advance. What that
  costs is a freshness indicator that lags by one cycle, and no more. It
  cannot cause a double booking: the availability cache has a short TTL, and
  the conflict check a booking runs reads the cached provider rows the busy
  write just replaced rather than anything the invalidation controls. Stamping
  and invalidating on the way out of a failing run would buy that one
  indicator at the price of an error path that also writes, so the
  short-circuit stands. The job's verdict is the error, and Oban retries the
  item read.

  ## The item half syncs incrementally, and re-reads in full once a day

  `SyncFolderItems` gives each folder a change feed behind a state token, so an
  ordinary cycle asks what changed rather than re-reading the window. A folder
  the feed reports nothing for is skipped entirely: no `FindItem`, no
  `GetItem`. One that reports changes costs a batched `GetItem` for the
  changed ids alone, and the deletions the feed states are applied by
  `provider_event_id`.

  Three things make that safe rather than merely cheaper, and all three matter.

  **The feed has no time window.** `SyncFolderItems` answers for the whole
  folder, so a change ten years out arrives like one next week. Changed items
  are fetched and then filtered to the sync window here; one that falls outside
  it is deleted from the cache rather than ignored, because an item *moved* out
  of the window has to stop being cached and the feed cannot say which of the
  two happened.

  **A moving window is not a change.** The window is ±`ProviderConfig`'s day
  counts from *now*, so it slides daily, and an item that slides into it never
  appears in the feed: nothing about it changed. Only the full re-read can pick
  those up, which is why one runs when `last_full_sync_at` is older than
  `@full_item_sync_after_seconds` — and why that interval must stay well under
  the window's own width, so an item cannot cross the whole edge unseen.

  **A token is bootstrapped once, never refreshed by a full read.** The first
  cycle for a folder does the full windowed read *and* drains the feed to
  establish a token, discarding the changes the full read already covered.
  Later full re-reads leave the token alone, so the next incremental cycle
  replays changes the full read has already applied. That replay is harmless
  because both halves are idempotent: an upsert rewrites a row that is already
  right, and a delete of a row that is already gone is a no-op. Re-bootstrapping
  on every full read would instead cost a whole-folder enumeration each time.

  A token the server later refuses (`ErrorInvalidSyncStateData` and its
  version sibling, classified by `Exchange.ItemSync.invalid_sync_state?/1`) is
  the one failure that recovers rather than being reported. The token is
  dropped and this cycle falls through to the full read, which re-bootstraps
  it. Reporting it instead is what the sync used to do, and it stalled the
  folder permanently: the refusal repeated every cycle, `last_external_sync_at`
  never advanced so the fallback sweep re-enqueued it, and the availability
  half was re-read in full each time for a grid half that could never succeed.

  The busy half has no incremental form — `GetUserAvailability` takes a window
  and answers intervals, with no token and no change feed — so it re-reads and
  replaces wholesale on every cycle, exactly as before.

  ## What this cycle deliberately does not do

  It calls neither reconciliation primitive, and the two are skipped for
  different reasons.

  `Calendar.Sync.reconcile_deletions/3` is the one that can cancel. A ref
  naming no `provider_event_id` falls back to the `uid`, which reaches
  `Meetings.ExternalCalendarChanges.find_linked_meeting/3` and can mark a
  real confirmed booking `"externally_deleted"`, notifying both parties.
  Every busy row written here carries a synthesised uid and no provider event
  id, which is exactly the shape that fallback resolves. The busy half never
  computes a vanished set to hand it: `full_refresh_for_role/3` replaces a
  role's rows wholesale, so a disappeared interval is a silent cache deletion.
  Not calling it is the structural half of the defence; the other half is the
  namespace `Exchange.IntervalNormaliser` puts on those uids.

  The incremental item half *does* now know which items vanished, and still
  does not call it. Those deletions are applied straight to the cache by
  `provider_event_id`. Cancelling a Tymeslot booking because its mirror row
  left an external calendar is a decision for the providers that own the
  booking, and this one does not: a `display_only` row blocks nothing, so
  removing it costs the grid an entry and no more.

  `Calendar.Sync.post_commit_reconciliation/2` could not cancel anything even
  if it ran: it walks the events *present* in the sync rather than vanished
  ones, and signals `:modified`, never `:deleted`. It is skipped on
  `SyncIcsCalendarWorker`'s narrower grounds instead: a read-only mirror of
  someone else's mailbox has no business rewriting Tymeslot meetings whose
  times moved. Its other two effects, the availability-cache invalidation and
  the grid broadcast, are wanted and are done directly by `run/1`.

  Two further reasons once stood here and no longer hold: that pass used to
  return early for every event with a nil `provider_event_id` — which is every
  synthesised busy row — and to resolve the rest by `provider_event_id` alone.
  It now matches on any shared identifier, uid included, so a synthesised row
  is a candidate like any other. The namespacing of those uids
  (`Exchange.IntervalNormaliser`) is what keeps them from colliding with a
  real booking, and skipping the pass entirely is the structural half of the
  same defence.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Exchange.IntervalNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.ItemCache
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  @busy_only EventRole.busy_only()
  @display_only EventRole.display_only()

  @doc """
  Runs one sync cycle of the Exchange integration `integration`: the
  availability half, then the item half, then the bookkeeping of a
  completed cycle (the availability cache, the grid broadcasts and the sync
  stamps).

  Returns `:ok`, or `{:error, reason}` in the CalDAV vocabulary
  `Exchange.Client` answers in, plus `:no_mailbox_address` and
  `{:empty_feed_with_populated_cache, role}`. Nothing is recorded against
  the integration on a failure: what a failure means is the caller's.
  """
  @spec run(CalendarIntegrationSchema.t()) :: :ok | {:error, term()}
  def run(%CalendarIntegrationSchema{} = integration) do
    with {:ok, uids, item_read} <- sync(integration) do
      complete(integration, uids, item_read)
    end
  end

  # The order is the design, not an accident: availability first, and its
  # failure stops the run before either half of the cache is touched.
  defp sync(integration) do
    {from, to} = Sync.window()

    with {:ok, busy_uids} <- refresh_busy_intervals(integration, from, to),
         {:ok, item_uids, item_read} <- refresh_items(integration, from, to) do
      {:ok, busy_uids ++ item_uids, item_read}
    end
  end

  # --- The availability half ---

  defp refresh_busy_intervals(integration, from, to) do
    context = %{calendar_integration_id: integration.id, synced_at: DateTime.utc_now()}

    with {:ok, intervals} <-
           Provider.list_busy_intervals(integration, start_time: from, end_time: to),
         {:ok, events} <- IntervalNormaliser.normalise_intervals(intervals, context) do
      write(integration, @busy_only, events, from, to)
    end
  end

  # --- The grid half ---

  # One client config per selected calendar. A failure on any one of them
  # fails the item read rather than caching a partial view: half a mailbox on
  # the grid is a grid nobody can trust.
  #
  # Which of the two reads runs is decided per integration rather than per
  # folder, so a run is either a full replacement or a set of incremental
  # edits, never a mix. A mix would have `full_refresh_for_role/3` delete the
  # rows the incremental folders had just written: that call is scoped to the
  # role across the whole integration, not to one folder.
  #
  # Which of the two ran is reported alongside the uids, because
  # `last_full_sync_at` is the input `ItemCache.full_sync_due?/1` reads back to
  # schedule the next full read. Stamping it after an incremental cycle would
  # hold it permanently fresh and the daily full re-read would never come due
  # again, so items sliding into the window would never be picked up.
  #
  # `{:error, :full_sync_required, integration}` is the incremental read asking
  # for the other one rather than failing: the server refused a stored token,
  # `ItemCache` has already dropped it, and the integration handed back is the
  # one without it, so the full read's bootstrap re-establishes it. Reporting
  # the refusal instead would have the folder fail identically every cycle,
  # forever.
  defp refresh_items(integration, from, to) do
    if ItemCache.full_sync_due?(integration) do
      full_refresh_items(integration, from, to)
    else
      case ItemCache.incremental_refresh(integration, from, to) do
        {:ok, uids} -> {:ok, uids, :incremental}
        {:error, :full_sync_required, integration} -> full_refresh_items(integration, from, to)
        {:error, _reason} = error -> error
      end
    end
  end

  defp full_refresh_items(integration, from, to) do
    with {:ok, events} <- fetch_all_calendars(integration, from, to),
         {:ok, uids} <- write(integration, @display_only, events, from, to) do
      ItemCache.bootstrap_sync_states(integration)
      {:ok, uids, :full}
    end
  end

  defp fetch_all_calendars(integration, from, to) do
    integration
    |> Provider.item_client_configs()
    |> Enum.reduce_while({:ok, []}, fn client, {:ok, acc} ->
      case fetch_one_calendar(integration, client, from, to) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_one_calendar(integration, client, from, to) do
    calendar_id = client.calendar_id
    context = ItemCache.item_context(integration, client)

    with {:ok, items} <-
           Provider.list_calendar_items(client,
             start_time: from,
             end_time: to,
             calendar_id: calendar_id
           ) do
      Provider.normalise_events(items, context)
    end
  end

  # --- Writing ---

  # Guarded per role. Asking whether the integration holds *any* rows would
  # have a populated grid half veto an honestly empty availability half, and
  # vice versa.
  defp write(integration, role, events, from, to) do
    with {:guard, :ok} <-
           {:guard, Sync.refuse_empty_over_populated(integration, role, events, {from, to})},
         {:ok, _count} <- Sync.full_refresh_for_role(integration, role, events) do
      {:ok, Enum.map(events, & &1.uid)}
    else
      {:guard, {:error, reason}} -> {:error, {reason, role}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Completing ---

  defp complete(integration, uids, item_read) do
    Sync.invalidate_cache_for_user(integration)
    SyncBroadcast.broadcast_cache_update(integration.user_id, uids)

    mark_synced(integration, length(uids), item_read)
    SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
    :ok
  end

  # `last_full_sync_at` moves only when the item half actually re-read its
  # whole window. It is not a general "this sync succeeded" marker here:
  # `ItemCache.full_sync_stale?/1` reads it back to decide when the next full
  # read is due, so an incremental cycle that stamped it would keep resetting
  # the very clock it is measured against. `last_external_sync_at` is the
  # per-cycle marker, and the sweep's own Exchange cadence reads it.
  #
  # Clearing `sync_error` and `needs_reauth` is not done here: it belongs to
  # every provider's successful cycle alike, so `SyncHealth.record_outcome/2`
  # owns it at the job boundary.
  defp mark_synced(integration, count, item_read) do
    now = DateTime.utc_now(:second)

    attrs = Map.merge(%{last_external_sync_at: now}, full_read_stamp(item_read, now))

    case CalendarIntegrationQueries.update_sync_state(integration, attrs) do
      {:ok, _updated} ->
        Logger.info("Exchange calendar refreshed",
          calendar_integration_id: integration.id,
          event_count: count
        )

        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Exchange sync state",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(changeset)
        )

        :ok
    end
  end

  defp full_read_stamp(:full, now), do: %{last_full_sync_at: now}
  defp full_read_stamp(:incremental, _now), do: %{}
end
