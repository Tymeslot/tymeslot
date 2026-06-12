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
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Meetings

  @typep integration_id :: integer()
  @typep signal :: :deleted | :modified

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
  """
  @spec upsert_cache(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert_cache(_integration, []), do: {:ok, 0}

  def upsert_cache(%CalendarIntegrationSchema{} = integration, calendar_events)
      when is_list(calendar_events) do
    attrs_list = Enum.map(calendar_events, &ProviderCalendarEventSchema.from_calendar_event/1)
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
    invalidate_cache_for_user(integration)

    uids = Enum.map(calendar_events, & &1.uid)
    SyncBroadcast.broadcast_cache_update(integration.user_id, uids)

    provider_event_ids = Enum.map(calendar_events, & &1.provider_event_id)

    meetings_by_id =
      Meetings.list_meetings_by_provider_event_ids(integration.id, provider_event_ids)

    Enum.each(calendar_events, &maybe_reconcile_time_change(integration, &1, meetings_by_id))
    :ok
  end

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
