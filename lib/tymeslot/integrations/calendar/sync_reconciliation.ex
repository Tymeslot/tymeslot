defmodule Tymeslot.Integrations.Calendar.SyncReconciliation do
  @moduledoc """
  Meeting-level reconciliation of external calendar changes.

  Every sync worker (Google, CalDAV, Outlook, etc.) reaches this module
  through `Tymeslot.Integrations.Calendar.Sync`, once its cache write has
  committed: `post_commit_reconciliation/2` for created and updated events,
  `reconcile_deletions/3` for deleted ones. Both are provider-agnostic and
  look up linked Tymeslot meetings by every identifier an event carries.

  The meeting-side consequences of a detected change (sync-status updates,
  auto-cancellation, host notifications) belong to the Meetings context and
  are delegated to `Tymeslot.Meetings.apply_external_calendar_change/5`.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.Calendar.TimingChange
  alias Tymeslot.Meetings
  alias Tymeslot.Profiles

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
  Side effects that must run after the cache upsert transaction commits:
  invalidating the availability cache, the PubSub broadcast, and the
  linked-meeting time-change reconciliation.

  Safe to call outside any transaction. Idempotent — availability cache
  invalidation, a PubSub re-broadcast, and time-change reconciliation are
  all safe to repeat.
  """
  @spec post_commit_reconciliation(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) :: :ok
  def post_commit_reconciliation(_integration, []), do: :ok

  def post_commit_reconciliation(%CalendarIntegrationSchema{} = integration, calendar_events)
      when is_list(calendar_events) do
    # Invalidate any cached availability for this user first, so subscribers
    # reacting to the PubSub broadcast below recompute against fresh events
    # instead of returning stale pre-sync slots.
    Sync.invalidate_cache_for_user(integration)

    uids = Enum.map(calendar_events, & &1.uid)
    SyncBroadcast.broadcast_cache_update(integration.user_id, uids)

    # Match on every identifier the events carry, not `provider_event_id`
    # alone: a CalDAV event holds its href there while the meeting it mirrors
    # is only reachable by UID, so an id-only join found no meeting for any
    # CalDAV integration and silently never reconciled a time change.
    identifiers =
      calendar_events
      |> Meetings.calendar_identifier_set()
      |> MapSet.to_list()

    meetings_by_identifier =
      Meetings.list_meetings_by_calendar_identifiers(integration.id, identifiers)

    # Read once for the batch, and only when an all-day event needs it.
    host_zone =
      if Enum.any?(calendar_events, & &1.all_day),
        do: Profiles.get_user_timezone(integration.user_id)

    Enum.each(
      calendar_events,
      &maybe_reconcile_time_change(integration, &1, meetings_by_identifier, host_zone)
    )

    :ok
  end

  defp maybe_reconcile_time_change(
         integration,
         %CalendarEvent{} = cal_event,
         meetings_by_identifier,
         host_zone
       ) do
    case linked_meeting(cal_event, meetings_by_identifier) do
      nil ->
        :ok

      # A booking the host turned into a recurring series comes back as the
      # series and its moved or cancelled occurrences, all carrying the
      # booking's UID. Only the series row describes the booking itself; an
      # occurrence elsewhere in the series would flag it, and the series row
      # clear it again, on every sync.
      _meeting when is_binary(cal_event.recurrence_id) or is_binary(cal_event.recurring_event_id) ->
        :ok

      meeting ->
        case TimingChange.classify(meeting, cal_event, host_zone) do
          :moved ->
            # A Tymeslot write to the event that finished at or after the
            # event's `synced_at` may be missing from it. The Outlook sweep and
            # re-bootstrap stamp `synced_at` with when their read began; other
            # paths stamp it just after the read, leaving only the read itself
            # uncovered.
            reconcile(integration.id, cal_event.provider_event_id, cal_event.uid, :modified,
              snapshot_at: cal_event.synced_at
            )

          {:end_moved, end_time} ->
            Meetings.apply_external_end_change(meeting, end_time)

          :none ->
            # Agreement is a signal too. This pass cannot know whether an earlier
            # one flagged the meeting, and nothing else retires the flag, so a
            # divergence that has since resolved would otherwise leave the host
            # with a badge and a notification that was never withdrawn.
            Meetings.resolve_external_calendar_change(meeting)

            # In step, or a difference already accepted: what the calendar
            # shows now is what a later end change is measured against. Not
            # recorded when the end moved, since a followed end records itself
            # and one that was refused must be seen as moved again next pass.
            Meetings.record_seen_calendar_end(meeting, TimingChange.seen_end(cal_event))
        end
    end
  end

  # Accepts anything carrying the two identity fields: a `CalendarEvent` from
  # the upsert path, a `deletion_ref()` from the deletion path.
  defp linked_meeting(record, meetings_by_identifier) when is_map(record) do
    record
    |> Meetings.calendar_event_identifiers()
    |> Enum.find_value(&Map.get(meetings_by_identifier, &1))
  end

  @doc """
  Removes externally deleted provider events from the local cache and
  reconciles any linked Tymeslot meetings.

  This is the deletion-side counterpart of `Tymeslot.Integrations.Calendar.Sync.persist_normalised_events/2` —
  the single primitive all sync workers use when a provider reports deleted
  events. For each ref:

  1. The cache rows are deleted, each ref by its `:uid` when it has one,
     falling back to `:provider_event_id`. Pass `delete_cache: false` when
     the cache rows were already deleted inside an enclosing
     `Repo.transaction` (e.g. the CalDAV atomic reconciler) and only the
     post-commit reconciliation side effects remain.
  2. The linked meeting (if any) is reconciled with `:deleted`. Reconcile
     failures are logged as warnings and do not abort the remaining refs —
     a failed auto-cancellation reverts its own sync status and is retried
     by the next sync run.

  Both steps are batched: the whole list costs two `DELETE`s and one `SELECT`
  rather than roughly three round-trips per ref, which matters because the
  common case is a cancelled event with no linked meeting paying the full
  cost to learn there is nothing to do. A backlog drain after a stuck sync
  token can be thousands of events in one job.

  Duplicate refs are collapsed, and so are two refs resolving to one meeting.
  Not for the database's sake (a batched `DELETE … WHERE uid IN (…)` is
  indifferent to duplicates, unlike the `ON CONFLICT DO UPDATE` in
  `ProviderCalendarEventQueries.upsert_batch/1`), and not for correctness either, since
  `update_calendar_sync_status_if_changed/2` already makes a repeated signal a
  no-op. It simply saves the repeated round-trip.

  Always returns `:ok`.
  """
  @spec reconcile_deletions(CalendarIntegrationSchema.t(), [deletion_ref()], keyword()) :: :ok
  def reconcile_deletions(integration, refs, opts \\ [])

  def reconcile_deletions(_integration, [], _opts), do: :ok

  def reconcile_deletions(%CalendarIntegrationSchema{} = integration, refs, opts)
      when is_list(refs) do
    refs = Enum.uniq_by(refs, &{Map.get(&1, :provider_event_id), Map.get(&1, :uid)})

    if Keyword.get(opts, :delete_cache, true) do
      delete_cached_events(integration.id, refs)
      SeriesRules.forget_orphans(integration.id)
    end

    reconcile_deleted_meetings(integration, refs)
  end

  # Mirrors the per-ref precedence exactly: a ref carrying a uid is deleted by
  # uid and never by provider event id, and a ref carrying neither is skipped.
  # Both query helpers chunk internally, so an arbitrarily long list is safe.
  defp delete_cached_events(integration_id, refs) do
    {by_uid, rest} = Enum.split_with(refs, &is_binary(Map.get(&1, :uid)))

    by_uid
    |> Enum.map(&Map.get(&1, :uid))
    |> then(&ProviderCalendarEventQueries.delete_by_uids(integration_id, &1))

    rest
    |> Enum.map(&Map.get(&1, :provider_event_id))
    |> Enum.filter(&is_binary/1)
    |> then(&ProviderCalendarEventQueries.delete_by_provider_event_ids(integration_id, &1))

    # A deleted series master takes its occurrences with it: Google and
    # Outlook cache each occurrence under its own uid, naming the master in
    # `recurring_event_id`. CalDAV rows never carry one, so this is inert there.
    refs
    |> Enum.map(&Map.get(&1, :provider_event_id))
    |> Enum.filter(&is_binary/1)
    |> then(&ProviderCalendarEventQueries.delete_by_recurring_event_ids(integration_id, &1))

    :ok
  end

  defp reconcile_deleted_meetings(integration, refs) do
    # A `deletion_ref()` carries the same two identifiers a meeting does, so it
    # feeds the shared identity rule directly: no conversion, and the uid
    # fallback a CalDAV deletion depends on comes with it. See
    # `Tymeslot.Meetings.CalendarEventLink`.
    identifiers = refs |> Meetings.calendar_identifier_set() |> MapSet.to_list()

    meetings_by_identifier =
      Meetings.list_meetings_by_calendar_identifiers(integration.id, identifiers)

    refs
    |> Enum.map(&linked_meeting(&1, meetings_by_identifier))
    |> Enum.reject(&is_nil/1)
    # One meeting can be reached by two refs: its uid and its provider event
    # id arriving as separate deletions. The repeat is already harmless
    # downstream, so this only saves the second round-trip.
    |> Enum.uniq_by(& &1.id)
    |> Enum.each(&reconcile_deleted_meeting(integration, &1))

    :ok
  end

  defp reconcile_deleted_meeting(integration, meeting) do
    case Meetings.apply_external_calendar_change_to_meeting(meeting, :deleted) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Reconcile failed for deleted event",
          calendar_integration_id: integration.id,
          meeting_id: meeting.id,
          provider_event_id: meeting.provider_event_id,
          reason: LogFormat.reason(reason)
        )
    end
  end

  @doc """
  Main reconciliation entry point.

  Called by all sync workers when detecting changes to linked meetings.
  Delegates the meeting-side consequences to the Meetings context.

  - `integration_id` — the calendar integration ID
  - `provider_event_id` — the provider-native event ID (may be `nil` for CalDAV)
  - `uid` — the iCal UID of the event (may be `nil` for Outlook deleted events)
  - `signal` — `:deleted` or `:modified`

  `opts` are passed through (see `Tymeslot.Meetings.apply_external_calendar_change/5`).

  Returns `:ok` when no action was needed (no linked meeting, already up-to-date)
  or when the status was successfully updated.
  """
  @spec reconcile(integration_id(), String.t() | nil, String.t() | nil, signal(), keyword()) ::
          :ok | {:error, term()}
  def reconcile(integration_id, provider_event_id, uid, signal, opts \\ []) do
    Meetings.apply_external_calendar_change(integration_id, provider_event_id, uid, signal, opts)
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
