defmodule Tymeslot.Integrations.Calendar.Sync do
  @moduledoc """
  The provider-agnostic write side of every calendar sync.

  Every sync worker (Google, CalDAV, Outlook, etc.) hands its normalised
  `CalendarEvent`s here rather than writing the cache itself:
  `persist_normalised_events/2` upserts the batch and runs the post-commit
  side effects, and callers that must write inside their own
  `Repo.transaction` call its two halves, `upsert_cache/2` and
  `post_commit_reconciliation/2`, separately. The full-refresh and
  drop-role functions cover the reads that replace a whole calendar's rows.

  Reconciling linked Tymeslot meetings with what the provider now shows
  (time changes and deletions) lives in
  `Tymeslot.Integrations.Calendar.SyncReconciliation`; this module keeps
  delegates to it so every worker has one entry point.

  It also holds the two rules every provider's sync shares: the window a
  sync reads (`window/1`), and the refusal to let an empty read wipe a
  populated cache (`refuse_empty_over_populated/4`).
  """

  alias Tymeslot.Availability
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarSeriesQueries
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Integrations.Calendar.SyncReconciliation
  alias Tymeslot.Meetings

  # How far back and forward a sync reads, for every provider alike, so the
  # dashboard calendar shows one range whichever calendar an event is on.
  @window_past_days 365
  @window_future_days 365

  @doc """
  The window a sync reads, around `now`: `window_past_days/0` back and as
  many days forward.
  """
  @spec window(DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def window(now \\ Clock.utc_now()),
    do:
      {DateTime.add(now, -@window_past_days, :day), DateTime.add(now, @window_future_days, :day)}

  @doc "How many days back a sync reads; older rows are no longer refreshed."
  @spec window_past_days() :: pos_integer()
  def window_past_days, do: @window_past_days

  @doc """
  Refuses to replace a populated cache with an empty read.

  A sync that reads a whole window replaces the rows it holds for it. An
  empty answer from a server that answered with events before is far more
  likely a bad read (a feed served empty mid-deploy, a mailbox briefly
  unreadable) than a calendar emptied for real, and wiping on that signal
  alone is damage the next sync cannot see to undo. So an empty `events`
  is refused while the integration still holds rows overlapping
  `{range_start, range_end}`: of `role`, or of any role when `role` is nil.
  The cache is left as it is and the cycle fails, to be retried.
  """
  @spec refuse_empty_over_populated(
          CalendarIntegrationSchema.t(),
          String.t() | nil,
          [CalendarEvent.t()],
          {DateTime.t(), DateTime.t()}
        ) :: :ok | {:error, :empty_feed_with_populated_cache}
  def refuse_empty_over_populated(integration, role, events, {range_start, range_end}) do
    if events == [] and
         CalendarEventQueries.any_in_range?(integration.id, role, range_start, range_end),
       do: {:error, :empty_feed_with_populated_cache},
       else: :ok
  end

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

  # Marks the events that mirror one of this integration's own bookings.
  #
  # Providers infer ownership from the payload where they can: Google stamps
  # `extendedProperties.private.createdBy`, and the iCal normaliser recognises a
  # `…@tymeslot.com` UID. Neither reaches a booking on a CalDAV or Outlook
  # calendar — a booking's UID is a bare `UUID.uuid4()` (`Bookings.Create`), so
  # `created_by_tymeslot` stayed false on every mirrored booking those providers
  # hold.
  #
  # That flag is load-bearing: `CalDAV.OfflineQueue` grants the `:keep_local`
  # force-write only to rows carrying it, so the recovery a conflicting write
  # depends on was inert for exactly the events it was written for.
  #
  # Callers writing through `upsert_cache/2` get this for free and must not call
  # it themselves; the one caller that needs it explicitly is
  # `full_refresh_for_role/3`, which writes by a different query.
  #
  # Ownership does not have to be inferred from the payload at all. A mirrored
  # booking shares an identifier with the meeting it came from, which is the
  # same rule the grid and the agenda deduplicate on, so resolve it against the
  # integration's meetings. Only ever raises the flag: a provider that already
  # recognised its own marker keeps it.
  @spec flag_tymeslot_owned(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) ::
          [CalendarEvent.t()]
  defp flag_tymeslot_owned(_integration, []), do: []

  defp flag_tymeslot_owned(%CalendarIntegrationSchema{} = integration, calendar_events) do
    identifiers =
      calendar_events
      |> Meetings.calendar_identifier_set()
      |> MapSet.to_list()

    case Meetings.list_meetings_by_calendar_identifiers(integration.id, identifiers) do
      empty when map_size(empty) == 0 ->
        calendar_events

      meetings_by_identifier ->
        Enum.map(calendar_events, &mark_if_owned(&1, meetings_by_identifier))
    end
  end

  defp mark_if_owned(%CalendarEvent{created_by_tymeslot: true} = event, _meetings), do: event

  defp mark_if_owned(%CalendarEvent{} = event, meetings_by_identifier) do
    owned? =
      event
      |> Meetings.calendar_event_identifiers()
      |> Enum.any?(&Map.has_key?(meetings_by_identifier, &1))

    %{event | created_by_tymeslot: owned?}
  end

  @doc """
  Replaces every cached row an integration holds under one `role`, in a single
  transaction, with the given events.

  For providers whose sync has more than one read path writing into the same
  integration. Exchange is the only one today: its busy-time read owns the
  `busy_only` rows and its item read owns the `display_only` ones, and an
  unscoped full refresh would have each half delete the other's rows every
  cycle.

  Pure DB write. **No `post_commit_reconciliation/2`, deliberately**, and not
  merely as the read-only-mirror argument `SyncIcsCalendarWorker` makes:
  reconciliation resolves a vanished event to a Tymeslot meeting *by uid*
  (`Meetings.ExternalCalendarChanges.find_linked_meeting/3`) and cancels it,
  notifying both parties. Rows written through here can carry a synthesised
  uid, because a busy interval arrives with no identity of any kind, so a uid
  collision would cancel a real confirmed booking. The synthesised uids are
  namespaced to make that collision unreachable; not running the
  reconciliation at all is the structural half of the same defence, and both
  are wanted.

  Ownership *is* flagged here, unlike reconciliation. `flag_tymeslot_owned/2`
  only ever raises `created_by_tymeslot` on a row that matches one of this
  integration's own meetings, so it cannot mislabel a synthesised busy
  interval, and Exchange reaches the cache through this function alone —
  without it, a booking mirrored to an Exchange calendar stays unowned and
  `CalDAV.OfflineQueue`-style recovery keyed on that flag never applies to it.
  """
  @spec full_refresh_for_role(CalendarIntegrationSchema.t(), String.t(), [CalendarEvent.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def full_refresh_for_role(%CalendarIntegrationSchema{} = integration, role, calendar_events)
      when is_binary(role) and is_list(calendar_events),
      do: full_refresh(integration, {:role, role}, role, calendar_events)

  @doc """
  `full_refresh_for_role/3` for the rows of one calendar alone: a read that
  answers for that calendar and no other, such as the busy periods of a
  CalDAV calendar shared as busy times only, replaces only its rows.
  """
  @spec full_refresh_for_calendar(
          CalendarIntegrationSchema.t(),
          String.t(),
          String.t(),
          [CalendarEvent.t()]
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def full_refresh_for_calendar(integration, provider_calendar_id, role, calendar_events)
      when is_binary(provider_calendar_id) and is_binary(role) and is_list(calendar_events),
      do:
        full_refresh(
          integration,
          {:calendar, provider_calendar_id, role},
          role,
          calendar_events
        )

  @doc """
  Drops the `role` rows of every calendar of the integration but
  `provider_calendar_ids`: the rows a per-calendar read
  (`full_refresh_for_calendar/4`) cached for a calendar it no longer reads.
  """
  @spec drop_role_except(CalendarIntegrationSchema.t(), String.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def drop_role_except(integration, role, provider_calendar_ids)
      when is_binary(role) and is_list(provider_calendar_ids),
      do:
        full_refresh(integration, {:role_except_calendars, role, provider_calendar_ids}, role, [])

  defp full_refresh(integration, scope, role, calendar_events) do
    attrs =
      integration
      |> flag_tymeslot_owned(calendar_events)
      |> Enum.map(
        &(&1
          |> ProviderCalendarEventSchema.from_calendar_event()
          |> Map.put(:role, role))
      )

    IntegrationCacheQueries.replace_cached_rows(integration.id, scope, attrs)
  rescue
    e ->
      ErrorTracking.report_error(e, __STACKTRACE__, %{
        calendar_integration_id: integration.id,
        role: role,
        event_count: length(calendar_events)
      })

      {:error, Exception.message(e)}
  end

  @doc """
  Writes a batch of normalised events to the local cache.

  No broadcast and no meeting reconciliation. Safe to call inside a
  `Repo.transaction`; a rollback unwinds the upsert cleanly.

  Ownership is flagged here rather than by the caller, because every sync path
  writes through this function. It used to be flagged a level up in
  `persist_normalised_events/2`, which the CalDAV reconciler does not call:
  it writes under a transaction and so goes to this function directly
  (`SyncReconciler.run_atomic_full_fetch/6` and `run_atomic_tier1/3`), and
  those are every tier CalDAV runs. The result was that no CalDAV row ever
  carried `created_by_tymeslot`, and the `:keep_local` recovery
  `CalDAV.OfflineQueue` grants on the strength of it applied to nothing.

  The cost is one meeting lookup per batch; `flag_tymeslot_owned/2` reads
  only, so it is safe inside the caller's transaction.

  A Google or Outlook occurrence is given its series' stored rule here too,
  read under the same lock (`SeriesRules.stamp/2`), since this write replaces
  a row's rule with whatever the event carries.
  """
  @spec upsert_cache(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert_cache(_integration, []), do: {:ok, 0}

  def upsert_cache(%CalendarIntegrationSchema{} = integration, calendar_events)
      when is_list(calendar_events) do
    IntegrationCacheQueries.under_lock(integration.id, fn ->
      attrs_list =
        integration
        |> flag_tymeslot_owned(SeriesRules.stamp(integration.id, calendar_events))
        |> Enum.map(&ProviderCalendarEventSchema.from_calendar_event/1)

      {:ok, count} = ProviderCalendarEventQueries.upsert_batch(attrs_list)
      drop_replaced_masters(integration.id, calendar_events)
      count
    end)
  rescue
    e ->
      ErrorTracking.report_error(e, __STACKTRACE__, %{
        calendar_integration_id: integration.id,
        event_count: length(calendar_events)
      })

      {:error, Exception.message(e)}
  end

  # Google and Outlook are listed as single occurrences, each naming its
  # series' master in `recurring_event_id`. A row cached for the master itself
  # (the grid caches a series it created that way) stands in for the whole
  # series and would show its first occurrence twice beside them, so it goes
  # once they arrive. CalDAV occurrences name no master, so this is inert there.
  #
  # The master's row may be the only place the series' video is recorded, as
  # it is for a series the grid created with one, and a sync never writes a
  # row's video; so before the row goes, its video is given to the
  # occurrences just cached that have none of their own.
  defp drop_replaced_masters(integration_id, calendar_events) do
    master_ids =
      calendar_events
      |> Enum.map(& &1.recurring_event_id)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    integration_id
    |> ProviderCalendarSeriesQueries.list_master_videos(master_ids)
    |> Enum.each(fn {master_id, video_integration_id, video_link} ->
      ProviderCalendarSeriesQueries.put_video(
        integration_id,
        {:master, master_id},
        nil,
        video_integration_id,
        video_link
      )
    end)

    ProviderCalendarEventQueries.delete_by_provider_event_ids(integration_id, master_ids)
  end

  @doc """
  Invalidates all cached availability data for a user after any sync mutation.

  Best-effort — if the cache GenServer is mid-restart and the ETS table is
  temporarily absent, the failure is recorded and `:ok` is returned.
  A committed sync transaction must not be unwound because of a transient
  cache state.
  """
  @spec invalidate_cache_for_user(CalendarIntegrationSchema.t()) :: :ok
  def invalidate_cache_for_user(%CalendarIntegrationSchema{} = integration) do
    Availability.changed(integration.user_id)
    :ok
  rescue
    e ->
      ErrorTracking.report_error(e, __STACKTRACE__, %{
        calendar_integration_id: integration.id,
        user_id: integration.user_id
      })
  end

  @doc "See `Tymeslot.Integrations.Calendar.SyncReconciliation.post_commit_reconciliation/2`."
  @spec post_commit_reconciliation(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) :: :ok
  defdelegate post_commit_reconciliation(integration, calendar_events), to: SyncReconciliation

  @doc "See `Tymeslot.Integrations.Calendar.SyncReconciliation.reconcile_deletions/3`."
  @spec reconcile_deletions(
          CalendarIntegrationSchema.t(),
          [SyncReconciliation.deletion_ref()],
          keyword()
        ) :: :ok
  defdelegate reconcile_deletions(integration, refs, opts \\ []), to: SyncReconciliation

  @doc "See `Tymeslot.Integrations.Calendar.SyncReconciliation.reconcile/5`."
  @spec reconcile(integer(), String.t() | nil, String.t() | nil, :deleted | :modified, keyword()) ::
          :ok | {:error, term()}
  defdelegate reconcile(integration_id, provider_event_id, uid, signal, opts \\ []),
    to: SyncReconciliation

  @doc "See `Tymeslot.Integrations.Calendar.SyncReconciliation.find_meeting/3`."
  @spec find_meeting(integer(), String.t() | nil, String.t() | nil) ::
          {:ok, term()} | {:error, :not_found}
  defdelegate find_meeting(integration_id, provider_event_id, uid), to: SyncReconciliation
end
