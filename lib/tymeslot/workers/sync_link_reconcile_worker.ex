defmodule Tymeslot.Workers.SyncLinkReconcileWorker do
  @moduledoc """
  Re-diffs one link's entire mirroring state and enqueues whatever the push path
  missed.

  The push path — `Sync.post_commit_reconciliation/2` enqueueing a write-back
  per changed event — is best-effort by design, and everything that makes it
  cheap also makes it lossy. An enqueue failure is logged and swallowed rather
  than failing the inbound sync. A webhook can be dropped by the provider. Three
  inbound paths reach the cache without passing through the hook at all (see
  below). This worker is what makes that acceptable: no single missed signal can
  leave a link permanently wrong, because the next sweep re-derives the answer
  from state rather than from events.

  ## The when, not the what

  Nothing here calls a provider. The diff produces `SyncLinkWriteBackWorker`
  jobs and stops, so a target that is down, throttled or merely slow cannot
  stall the reconcile — one link with a thousand stale mirrors costs one row per
  mirror in the queue, not a thousand serial round trips inside a single job.
  `unique` on `[:sync_link_id]` keeps two sweeps' worth of reconciles for the
  same link from running at once and enqueueing everything twice.

  ## The sync window, and the deletion it must not cause

  The diff reads source events from `CalendarEventQueries.in_range/2` over
  `ProviderConfig.sync_window_past_days()` to `sync_window_future_days()` — a
  year either side of now. That is not an arbitrary choice: it is exactly the
  window every provider fetch populates the cache with, so reconciling over a
  wider one would compare mappings against events the cache was never going to
  hold, and a narrower one would leave events inside the synced range
  permanently unreconciled.

  What the window must never do is decide a *deletion*. A windowed re-diff sees
  part of the calendar, so "not among the events I read" and "no longer on the
  calendar" are different statements, and conflating them is the failure mode
  this design is shaped around: every mirror for an event outside the window —
  a venue booked three years out, an anniversary in the distant past — would be
  torn down on the first sweep, all at once, with the mapping row deleted so
  nothing records that it happened.

  So absence from the window is never evidence of anything. A mapping is
  enqueued for deletion only when `ProviderCalendarEventQueries.existing_uids/2`
  confirms the cache holds no row for that UID under the source integration *at
  any date*, or when the source is present and has genuinely stopped being an
  eligible mirror source. A mapping whose source sits outside the window is
  simply left alone: it is not evidence of drift, and the sweep that finally
  sees it — when the event drifts into range — will reconcile it then.

  The same asymmetry runs the other way. Only events *inside* the window can be
  enqueued for creation or update, because only those were read. An event
  outside it is neither created nor destroyed by this pass.

  ## What the diff produces

  - an eligible source with no mapping → `:upsert` (the push path missed it)
  - a mapping whose source is absent from the cache entirely → `:delete`
  - a mapping whose source is cached but no longer an eligible source —
    cancelled, transparent, or now itself a mirror → `:delete`
  - a mapping whose source `provider_updated_at` is newer than the mapping's
    `source_updated_at` → `:upsert`
  - a mapping in `pending_delete` → `:delete`, retried. This is the state
    `Engine.unmirror/3` leaves behind when the provider delete fails, and Oban's
    attempts on the original job are long exhausted by the time a sweep runs.
    It is checked before the timestamp comparison, because a mapping being torn
    down must not be resurrected by an unrelated edit to its source.

  `last_reconciled_at` is stamped on completion, which is what the sweep filters
  on to decide the link is not due again.

  ## The three inbound paths that bypass the push hook

  These reach `ProviderCalendarEventQueries.upsert_batch/1` without going
  through `Sync.post_commit_reconciliation/2`, so an event arriving through one
  of them enqueues no mirror write and is picked up here instead. The decision
  for each is to leave it to this sweep rather than to add a hook, and the
  reasoning differs per site:

  - **ICS feed refresh** (`SyncIcsCalendarWorker`) — the deliberate one, and the
    one with a real cost. A subscription is read-only, so it can only ever be a
    *source*, which is exactly the case where mirroring is the whole point. But
    the worker calls `full_refresh_for_integration/2`, replacing the
    integration's events wholesale, and it does not distinguish a changed event
    from an unchanged one: hooking it would enqueue a write-back for every event
    in the feed on every refresh, thirty minutes apart, forever. That is a
    standing load proportional to feed size rather than to change, against
    targets whose quota is shared with the paths that do carry user-visible
    latency. The trade accepted is up to 30 minutes of extra staleness on
    mirrors sourced from a subscription — a feed the publisher regenerates on
    its own schedule anyway, and which `FallbackSyncSweepWorker` already refuses
    to poll more often than every 30 minutes for the same reason.
  - **Outlook delta sweep** (`Outlook.DeltaSync.apply_delta/3`) — this one *does*
    know what changed, so the objection above does not apply, but it runs inside
    the fallback sweep's own job and its `{removed, changed}` split already
    routes deletions through `Sync.reconcile_deletions/2`. Hooking only the
    changed half would leave the two halves of one delta taking different paths
    to the mirror, which is a seam that has to be got right on every future edit
    to either. Deferred deliberately: it is the strongest candidate of the three
    for a later hook, and the cost of not having one is bounded by this sweep.
  - **Outlook bootstrap** (`GraphSubscription.bootstrap_sync/1`) — a first-run
    baseline of an integration that, by definition, has no links pointing at it
    yet; a link cannot be configured against an integration before it connects.
    Anything it writes is reconciled by the first sweep after a link is created,
    which is also the first moment mirroring means anything. No hook is
    warranted.
  """
  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 3,
    priority: 5,
    unique: [
      keys: [:sync_link_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack

  @typedoc "What Oban is handed back, unchanged from the other sync-link workers."
  @type result :: :ok | {:error, term()} | {:discard, term()}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: result()
  def perform(%Oban.Job{args: %{"sync_link_id" => sync_link_id}}) do
    case CalendarSyncLinkQueries.get(sync_link_id) do
      # Paused means no writes in either direction, and that includes the ones
      # this sweep would have produced. Matched before any work is done: a
      # disabled link's drift is not drift, it is the organiser's instruction.
      #
      # Except when it is still holding placeholders down. Teardown disables the
      # link *before* withdrawing them, so a provider that refused the delete
      # leaves a disabled link whose busy blocks are still on someone's
      # calendar — and discarding there would strand them for good, which is the
      # orphan teardown exists to prevent. Those withdrawals are finished here;
      # nothing else is, so a paused link still writes no new placeholder.
      {:ok, %CalendarSyncLinkSchema{enabled: false} = link} ->
        finish_withdrawals(link)

      {:ok, link} ->
        reconcile(link)

      {:error, :not_found} ->
        {:discard, :link_not_found}
    end
  end

  # Only the teardown's unfinished business, never a fresh write. A mapping in
  # `pending_delete` names a placeholder the organiser has already asked to be
  # rid of; anything else on a paused link is left exactly as it is.
  defp finish_withdrawals(link) do
    case CalendarSyncMirrorQueries.list_pending_delete_for_link(link.id) do
      [] ->
        {:discard, :link_disabled}

      mirrors ->
        Enum.each(mirrors, &WriteBack.enqueue(link.id, &1.source_uid, :delete))
        :ok
    end
  end

  defp reconcile(%CalendarSyncLinkSchema{} = link) do
    mappings = CalendarSyncMirrorQueries.list_for_link(link.id)
    {in_window, sources} = window_events(link)

    enqueue_missing_and_stale(link, sources, mappings)
    enqueue_withdrawals(link, sources, in_window, mappings)

    stamp(link)
  end

  # Two results from one read, and the second is what makes the deletion rule
  # safe. `sources` is the eligible subset — the events that should have
  # placeholders. `in_window` is every UID the window contained, eligible or
  # not, which is how a mapping whose source was read and rejected is told apart
  # from one whose source was never read at all.
  #
  # The mirror set is the loop-prevention input, scoped to the source calendar
  # for the same reason the write-back worker scopes it: a placeholder written
  # onto *this* link's source by the link pointing the other way is a leaf, and
  # reconciliation must not be the path that finally mirrors it.
  defp window_events(link) do
    mirrors = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.source_integration_id])

    events = CalendarEventQueries.in_range([link.source_integration_id], window())

    sources =
      events
      |> Enum.filter(&Eligibility.mirror_source?(&1, mirrors, target_provider(link)))
      |> Map.new(&{&1.uid, &1})

    {MapSet.new(events, & &1.uid), sources}
  end

  # Named for `Eligibility`, which needs it for one decision: whether a
  # recurring source may be mirrored onto this link's target. Preloaded by
  # `CalendarSyncLinkQueries.get/1`. A link whose association could not be
  # loaded yields `nil`, which `Capability` treats as an unrecognised provider
  # and so refuses a series — the same direction the write-back worker takes,
  # and the one that leaves a wrong placeholder off the calendar.
  defp target_provider(%{target_integration: %{provider: provider}}), do: provider
  defp target_provider(_link), do: nil

  defp enqueue_missing_and_stale(link, sources, mappings) do
    by_uid = Map.new(mappings, &{&1.source_uid, &1})

    Enum.each(sources, fn {uid, event} ->
      case Map.get(by_uid, uid) do
        nil -> WriteBack.enqueue(link.id, uid, :upsert, moved: :preserve)
        mapping -> reconcile_mapped(link, mapping, event)
      end
    end)
  end

  # A teardown already in progress outranks any edit to the source. Checked
  # first so an unrelated change to a cancelled meeting cannot flip a mapping
  # out of `pending_delete` and rewrite the placeholder that was being removed.
  defp reconcile_mapped(link, %{state: "pending_delete", source_uid: uid}, _event),
    do: WriteBack.enqueue(link.id, uid, :delete)

  defp reconcile_mapped(link, mapping, event) do
    if stale?(mapping, event) do
      WriteBack.enqueue(link.id, mapping.source_uid, :upsert, moved: :preserve)
    else
      :ok
    end
  end

  # A source with no `provider_updated_at` gives nothing to compare, so it is
  # treated as unchanged rather than as changed. The alternative re-enqueues
  # every such mapping on every sweep for as long as the link exists — an
  # unbounded standing load for a provider that simply does not report the
  # field. The push path still catches genuine edits to these events.
  defp stale?(_mapping, %{provider_updated_at: nil}), do: false
  defp stale?(%{source_updated_at: nil}, _event), do: true

  defp stale?(%{source_updated_at: mapped}, %{provider_updated_at: source}),
    do: DateTime.compare(source, mapped) == :gt

  # The dangerous half of the diff. See the moduledoc: a mapping missing from
  # `sources` may mean the source was deleted, or merely that it lies outside
  # the window, and only the first is a reason to withdraw a placeholder. The
  # cache is asked directly, without a range, and only a UID it does not hold at
  # any date — or one it holds in a state that is no longer an eligible source —
  # produces a delete.
  defp enqueue_withdrawals(link, sources, in_window, mappings) do
    unmatched = Enum.reject(mappings, &Map.has_key?(sources, &1.source_uid))

    # Only the mappings the window did not account for need the extra read. One
    # whose source was read and rejected by eligibility is already known to be a
    # withdrawal and costs nothing further.
    unexplained = Enum.reject(unmatched, &MapSet.member?(in_window, &1.source_uid))

    still_cached =
      ProviderCalendarEventQueries.existing_uids(
        link.source_integration_id,
        Enum.map(unexplained, & &1.source_uid)
      )

    {out_of_window, withdrawn} =
      Enum.split_with(unmatched, fn mapping ->
        MapSet.member?(still_cached, mapping.source_uid)
      end)

    Enum.each(withdrawn, &WriteBack.enqueue(link.id, &1.source_uid, :delete))

    log_out_of_window(link, out_of_window)
  end

  defp log_out_of_window(_link, []), do: :ok

  defp log_out_of_window(link, mappings) do
    Logger.debug("Reconcile left out-of-window mirror mappings untouched",
      sync_link_id: link.id,
      count: length(mappings)
    )
  end

  defp stamp(link) do
    case CalendarSyncLinkQueries.update(link, %{
           last_reconciled_at: DateTime.utc_now(:microsecond)
         }) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        # The diff has already been enqueued, so the work is done; only the
        # bookkeeping that keeps the sweep from repeating it failed. Surfaced as
        # an error so Oban retries rather than leaving the link permanently
        # looking overdue.
        {:error, changeset}
    end
  end

  defp window do
    now = DateTime.utc_now()

    {DateTime.add(now, -ProviderConfig.sync_window_past_days(), :day),
     DateTime.add(now, ProviderConfig.sync_window_future_days(), :day)}
  end
end
