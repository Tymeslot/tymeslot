defmodule Tymeslot.Integrations.Calendar.Sync do
  @moduledoc """
  Meeting-level reconciliation logic for external calendar changes.

  This module owns change *detection* when a sync worker reports provider
  events that may be linked to Tymeslot meetings. It is provider-agnostic —
  all sync workers (Google, CalDAV, Outlook, etc.) call `reconcile/4` with a
  normalised signal.

  The meeting-side consequences of a detected change (sync-status updates,
  auto-cancellation, host notifications) belong to the Meetings context and
  are delegated to `Tymeslot.Meetings.apply_external_calendar_change/4`.

  Cache writes happen in the sync workers themselves. This module only runs
  when a linked Tymeslot meeting is found.
  """

  require Logger

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility
  alias Tymeslot.Integrations.Calendar.SyncLink.MovedOccurrence
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Meetings

  @typep integration_id :: integer()
  @typep signal :: :deleted | :modified

  @typedoc """
  Identifies an externally deleted provider event by `:provider_event_id`
  and/or `:uid` — whichever identifiers the provider's deletion signal
  carries. At least one should be non-nil for the deletion to have effect.
  """
  @type deletion_ref :: %{
          optional(:provider_event_id) => String.t() | nil,
          optional(:uid) => String.t() | nil
        }

  @doc """
  Persists a batch of normalised calendar events to the local cache and
  performs downstream side effects.

  Called by every sync worker after its provider-specific `normalise_events/2`
  returns. This is the single point where canonical `CalendarEvent` structs
  become rows in the cache — no sync worker should upsert directly.

  Steps:
  1. Convert each event to cache attrs via `from_calendar_event/1`.
  2. Upsert the batch in a single query.
  3. Invalidate the user's availability cache so subsequent slot lookups
     reflect the newly persisted events.
  4. Broadcast a cache update so live grids refresh.
  5. Reconcile any linked Tymeslot meetings whose times changed externally.

  This function is a convenience wrapper around `upsert_cache/2` and
  `post_commit_reconciliation/2` — callers that need to run the cache
  write inside a `Repo.transaction` alongside other DB work (e.g. the
  CalDAV atomic reconciler) should call those two halves separately.
  """
  @spec persist_normalised_events(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) ::
          :ok | {:error, term()}
  def persist_normalised_events(_integration, []), do: :ok

  def persist_normalised_events(%CalendarIntegrationSchema{} = integration, calendar_events)
      when is_list(calendar_events) do
    with {:ok, _count} <- upsert_cache(integration, calendar_events) do
      post_commit_reconciliation(integration, calendar_events)
      :ok
    end
  end

  @doc """
  Writes a batch of normalised events to the local cache.

  Pure DB write — no broadcast, no meeting reconciliation. Safe to call
  inside a `Repo.transaction`; a rollback unwinds the upsert cleanly.

  Cancellation tombstones are dropped here and never reach a row. See
  `reject_tombstones/1` for why this is the seam that has to do it.
  """
  @spec upsert_cache(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert_cache(_integration, []), do: {:ok, 0}

  def upsert_cache(%CalendarIntegrationSchema{} = integration, calendar_events)
      when is_list(calendar_events) do
    attrs_list =
      calendar_events
      |> reject_tombstones()
      |> Enum.map(&ProviderCalendarEventSchema.from_calendar_event/1)

    ProviderCalendarEventQueries.upsert_batch(attrs_list)
  rescue
    e ->
      Logger.error("Calendar event cache upsert raised an exception",
        calendar_integration_id: integration.id,
        event_count: length(calendar_events),
        reason: Exception.message(e)
      )

      {:error, Exception.message(e)}
  end

  # Detection must see a tombstone; the cache must never hold one. That split is
  # the whole reason this function exists, and it is enforced here rather than
  # asked of callers.
  #
  # `persist_normalised_events/2` hands the *same* list to `upsert_cache/2` and
  # `post_commit_reconciliation/2`, because the second needs the uncollapsed
  # batch the first collapses. A tombstone carries the **series** uid — that is
  # what makes it reach the right mirror row — and `upsert_batch/1` deduplicates
  # on `{calendar_integration_id, uid}` keeping the last entry. So a tombstone
  # arriving after its siblings in one delta would overwrite the series' cache
  # row with `status: :cancelled` and no timing at all, deleting the row the
  # placeholder is expanded from and unblocking every occurrence still
  # scheduled. That is a strictly worse failure than the stale block this path
  # exists to clear.
  #
  # Filtering at the cache seam rather than at the call site covers every
  # provider's write in one place — the CalDAV reconciler calls `upsert_cache/2`
  # directly from inside its transaction — and leaves the detection side reading
  # the full batch, which is the only place a per-instance marker still exists.
  defp reject_tombstones(calendar_events),
    do: Enum.reject(calendar_events, &CalendarEvent.tombstone?/1)

  @doc """
  Invalidates all cached availability data for a user after any sync mutation.

  Best-effort — if the cache GenServer is mid-restart and the ETS table is
  temporarily absent, the error is logged as a warning and `:ok` is returned.
  A committed sync transaction must not be unwound because of a transient
  cache state.
  """
  @spec invalidate_cache_for_user(CalendarIntegrationSchema.t()) :: :ok
  def invalidate_cache_for_user(%CalendarIntegrationSchema{} = integration) do
    AvailabilityCache.invalidate_for_user(integration.user_id)
    :ok
  rescue
    e ->
      Logger.warning("Availability cache invalidation failed — cache may be mid-restart",
        calendar_integration_id: integration.id,
        user_id: integration.user_id,
        reason: Exception.message(e)
      )

      :ok
  end

  @doc """
  Side effects that must run after the cache upsert transaction commits:
  invalidating the availability cache, the PubSub broadcast, the
  linked-meeting time-change reconciliation, enqueueing cross-calendar mirror
  write-backs, and reporting any moved occurrence of a mirrored series.

  Safe to call outside any transaction. Idempotent — availability cache
  invalidation, a PubSub re-broadcast, time-change reconciliation and a
  write-back enqueue (which collapses onto any pending job for the same event)
  are all safe to repeat, and the moved-occurrence report compares against what
  it last recorded rather than appending per call.

  `calendar_events` is the **uncollapsed** batch: the dedup that reduces a
  recurring series to one cache row happens inside `upsert_batch/1`, which has
  already run by the time this is called. That makes this the only place a
  per-instance property of a series can still be read, and
  `SyncLink.MovedOccurrence` is the one thing that needs it.
  """
  @spec post_commit_reconciliation(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) :: :ok
  def post_commit_reconciliation(_integration, []), do: :ok

  def post_commit_reconciliation(%CalendarIntegrationSchema{} = integration, calendar_events)
      when is_list(calendar_events) do
    # Invalidate any cached availability for this user first, so subscribers
    # reacting to the PubSub broadcast below recompute against fresh events
    # instead of returning stale pre-sync slots.
    invalidate_cache_for_user(integration)

    uids = Enum.map(calendar_events, & &1.uid)
    SyncBroadcast.broadcast_cache_update(integration.user_id, uids)

    provider_event_ids = Enum.map(calendar_events, & &1.provider_event_id)

    meetings_by_id =
      Meetings.list_meetings_by_provider_event_ids(integration.id, provider_event_ids)

    Enum.each(calendar_events, &maybe_reconcile_time_change(integration, &1, meetings_by_id))

    # One lookup, two consumers. Both ask the same question — which enabled
    # links mirror out of this calendar — and both are asked after every sync of
    # every calendar, so issuing it twice would double a query for an answer
    # that cannot change in between. The enqueue needs the links to fan jobs
    # out across; the moved-occurrence report needs them to decide whether any
    # move here has a consequence at all.
    links = CalendarSyncLinkQueries.list_enabled_for_source(integration.id)

    enqueue_mirror_write_backs(integration, calendar_events, links)
    MovedOccurrence.report(calendar_events, links)
    :ok
  end

  # Cross-calendar mirroring joins the pipeline here, and only ever as an
  # enqueue. A provider call at this point would put the *target* calendar's
  # latency inside the *source* calendar's sync, so a target that is slow, down
  # or over quota could stall an inbound sync it has nothing to do with. The
  # Oban job absorbs that instead, with its own retries and its own backoff.
  #
  # The mirror set is fetched once for the whole batch rather than per event.
  # It is the loop-prevention input: an event on this calendar that is itself a
  # placeholder must not spawn another, and asking per event would issue a query
  # per synced event on every sync of every calendar.
  #
  # `mirror_uids_for_sync/1`, not `mirror_uids_for_integrations/1`: the latter
  # is keyed on the mirror's *target*, so a placeholder that landed on the
  # link's source — which is what a deauthorised target caused — matched
  # nothing here and was mirrored again as though it were an ordinary event.
  defp enqueue_mirror_write_backs(_integration, _calendar_events, []), do: :ok

  defp enqueue_mirror_write_backs(integration, calendar_events, links) do
    integration.id
    |> filter_mirrorable(calendar_events)
    |> Enum.each(fn event ->
      moved = preserve_corrections(event)
      Enum.each(links, &WriteBack.enqueue(&1.id, event.uid, :upsert, moved))
    end)
  end

  # A pending correction on a series has to be carried across this enqueue, and
  # only a series pays for the lookup that does it.
  #
  # `WriteBack.enqueue/4` collapses onto a pending job by replacing its args
  # wholesale, and this path enqueues a plain `upsert` for every event of every
  # sync. A correction attached by `MovedOccurrence.report/2` is therefore
  # destroyed by the next sync that touches the same series before the job runs.
  #
  # For a move that was survivable: the moved instance keeps carrying an
  # `originalStartTime` differing from its `start`, so any delta containing it
  # re-detects and re-attaches the correction. A **cancellation has no second
  # chance**. Google reports a cancelled occurrence in exactly one delta and
  # omits it from every later one, so once the args are replaced the EXDATE is
  # gone permanently and the placeholder blocks the cleared slot forever.
  # Measured live: the single write-back job that ran after a mid-series
  # cancellation carried `moved = nil` and rewrote the placeholder to a bare
  # rule.
  #
  # `:preserve` is the mechanism `SyncLinkReconcileWorker` and `Remirror`
  # already use for precisely this reason. It was kept off this path because it
  # costs a query per enqueue and this path runs per event per link on every
  # sync. Gating it on the event naming a series keeps that argument intact —
  # an ordinary event still pays nothing — while covering every event that can
  # carry a correction, since only an occurrence of a series ever does.
  defp preserve_corrections(%CalendarEvent{recurring_event_id: id})
       when is_binary(id) and id != "",
       do: [moved: :preserve]

  defp preserve_corrections(_event), do: []

  defp maybe_reconcile_time_change(
         _integration,
         %CalendarEvent{provider_event_id: nil},
         _meetings_by_id
       ),
       do: :ok

  defp maybe_reconcile_time_change(
         integration,
         %CalendarEvent{} = cal_event,
         meetings_by_id
       ) do
    case Map.get(meetings_by_id, cal_event.provider_event_id) do
      nil ->
        :ok

      meeting ->
        if time_changed?(meeting.start_time, cal_event) do
          reconcile(integration.id, cal_event.provider_event_id, cal_event.uid, :modified)
        else
          :ok
        end
    end
  end

  # All-day event: compare start_date and end_date only.
  defp time_changed?(meeting_start_time, %CalendarEvent{all_day: true} = cal_event) do
    meeting_start_date = DateTime.to_date(meeting_start_time)
    cal_event.start_date != meeting_start_date
  end

  # Timed event with no start_at — should not occur for valid timed events, treat as unchanged.
  defp time_changed?(_meeting_start_time, %CalendarEvent{all_day: false, start_at: nil}),
    do: false

  defp time_changed?(meeting_start_time, %CalendarEvent{all_day: false, start_at: event_start}) do
    DateTime.compare(
      DateTime.truncate(meeting_start_time, :second),
      DateTime.truncate(event_start, :second)
    ) != :eq
  end

  @doc """
  Drops the events on this calendar that are placeholders of our own.

  Public because it is the only observable half of `enqueue_mirror_write_backs/3`
  — the rest is an Oban insert — and the question it answers is the one that
  went wrong: a placeholder redirected onto the link's *source* was invisible to
  a set keyed on the mirror's target, so the source's next sync mirrored it
  again.
  """
  @spec filter_mirrorable(integer(), [map()]) :: [map()]
  def filter_mirrorable(integration_id, calendar_events) when is_integer(integration_id) do
    mirrors = CalendarSyncMirrorQueries.mirror_uids_for_sync(integration_id)

    Enum.filter(calendar_events, &Eligibility.worth_enqueueing?(&1, mirrors))
  end

  @doc """
  Removes externally deleted provider events from the local cache and
  reconciles any linked Tymeslot meetings.

  This is the deletion-side counterpart of `persist_normalised_events/2` —
  the single primitive all sync workers use when a provider reports deleted
  events. For each ref:

  1. The cache row is deleted — by `:uid` when present, falling back to
     `:provider_event_id`. Pass `delete_cache: false` when the cache rows
     were already deleted inside an enclosing `Repo.transaction` (e.g. the
     CalDAV atomic reconciler) and only the post-commit reconciliation
     side effects remain.
  2. The linked meeting (if any) is reconciled with `:deleted`. Reconcile
     failures are logged as warnings and do not abort the remaining refs —
     a failed auto-cancellation reverts its own sync status and is retried
     by the next sync run.

  Always returns `:ok`.
  """
  @spec reconcile_deletions(CalendarIntegrationSchema.t(), [deletion_ref()], keyword()) :: :ok
  def reconcile_deletions(integration, refs, opts \\ [])

  def reconcile_deletions(_integration, [], _opts), do: :ok

  def reconcile_deletions(%CalendarIntegrationSchema{} = integration, refs, opts)
      when is_list(refs) do
    delete_cache? = Keyword.get(opts, :delete_cache, true)

    Enum.each(refs, fn ref ->
      provider_event_id = Map.get(ref, :provider_event_id)
      uid = Map.get(ref, :uid)

      if delete_cache?, do: delete_cached_event(integration.id, provider_event_id, uid)

      case reconcile(integration.id, provider_event_id, uid, :deleted) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Reconcile failed for deleted event",
            calendar_integration_id: integration.id,
            provider_event_id: provider_event_id,
            uid: uid,
            reason: inspect(reason)
          )
      end
    end)

    enqueue_mirror_withdrawals(integration, refs)

    :ok
  end

  # The deletion counterpart of `enqueue_mirror_write_backs/3`, and the same
  # rule applies: enqueue only, never a provider call. A source event vanishing
  # has to withdraw the placeholder it caused on every calendar it was mirrored
  # to, and doing that inline would put the *target's* latency inside the
  # *source's* sync — a target that is slow or down could then stall an inbound
  # sync it has nothing to do with. The Oban job absorbs that instead.
  #
  # It lives here rather than in `post_commit_reconciliation/2` because that
  # function is the upsert path and a deletion never reaches it: every
  # provider's deletion route — Google's cancelled events, Outlook's delta
  # `@removed`, CalDAV's absent uids — funnels through this one primitive, so
  # hooking it here covers all of them rather than three call sites that have
  # to be kept in step. It is safe to enqueue from: no caller runs this inside
  # a `Repo.transaction`. The CalDAV reconciler, the only path that wraps its
  # cache writes in one, deliberately calls this *after* the commit.
  #
  # The link lookup is one query for the whole batch, not one per ref, and is
  # skipped entirely for a calendar that is nobody's source — which is the
  # common case.
  defp enqueue_mirror_withdrawals(integration, refs) do
    case CalendarSyncLinkQueries.list_enabled_for_source(integration.id) do
      [] ->
        :ok

      links ->
        # Only a uid can name a placeholder: the mirror's `source_uid` is the
        # source event's uid, and the deterministic target uid is derived from
        # it. Outlook's delta reports some removals with no iCalUID at all, and
        # there is nothing to withdraw by in that case — the reconcile sweep
        # remains the backstop.
        refs
        |> Enum.map(&Map.get(&1, :uid))
        |> Enum.filter(&is_binary/1)
        |> Enum.each(fn uid ->
          Enum.each(links, &WriteBack.enqueue(&1.id, uid, :delete))
        end)
    end
  end

  defp delete_cached_event(integration_id, _provider_event_id, uid) when is_binary(uid) do
    ProviderCalendarEventQueries.delete_by_uid(integration_id, uid)
  end

  defp delete_cached_event(integration_id, provider_event_id, _uid)
       when is_binary(provider_event_id) do
    ProviderCalendarEventQueries.delete_by_provider_event_id(integration_id, provider_event_id)
  end

  defp delete_cached_event(_integration_id, _provider_event_id, _uid), do: :ok

  @doc """
  Main reconciliation entry point.

  Called by all sync workers when detecting changes to linked meetings.
  Delegates the meeting-side consequences to the Meetings context.

  - `integration_id` — the calendar integration ID
  - `provider_event_id` — the provider-native event ID (may be `nil` for CalDAV)
  - `uid` — the iCal UID of the event (may be `nil` for Outlook deleted events)
  - `signal` — `:deleted` or `:modified`

  Returns `:ok` when no action was needed (no linked meeting, already up-to-date)
  or when the status was successfully updated.
  """
  @spec reconcile(integration_id(), String.t() | nil, String.t() | nil, signal()) ::
          :ok | {:error, term()}
  def reconcile(integration_id, provider_event_id, uid, signal) do
    Meetings.apply_external_calendar_change(integration_id, provider_event_id, uid, signal)
  end

  @doc """
  Looks up a meeting linked to a calendar event by provider event ID or UID.

  Returns `{:ok, meeting}` if a linked meeting is found, `{:error, :not_found}`
  otherwise. Tries `provider_event_id` first, falls back to `uid`.
  """
  @spec find_meeting(integration_id(), String.t() | nil, String.t() | nil) ::
          {:ok, term()} | {:error, :not_found}
  def find_meeting(integration_id, provider_event_id, uid) do
    Meetings.find_meeting_by_calendar_event(integration_id, provider_event_id, uid)
  end
end
