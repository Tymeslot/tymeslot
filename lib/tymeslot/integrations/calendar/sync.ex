defmodule Tymeslot.Integrations.Calendar.Sync do
  @moduledoc """
  Meeting-level reconciliation logic for external calendar changes.

  This module owns all reconciliation decisions when a sync worker detects
  that a provider event linked to a Tymeslot meeting has been modified or
  deleted externally. It is provider-agnostic — all sync workers (Google,
  CalDAV, Outlook, etc.) call `reconcile/4` with a normalised signal.

  Cache writes happen in the sync workers themselves. This module only runs
  when a linked Tymeslot meeting is found.
  """

  require Logger

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Meetings.MeetingCalendarQueries

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
  3. Broadcast a cache update so live grids refresh.
  4. Reconcile any linked Tymeslot meetings whose times changed externally.
  """
  @spec persist_normalised_events(CalendarIntegrationSchema.t(), [CalendarEvent.t()]) ::
          :ok | {:error, term()}
  def persist_normalised_events(_integration, []), do: :ok

  def persist_normalised_events(%CalendarIntegrationSchema{} = integration, calendar_events)
      when is_list(calendar_events) do
    attrs_list = Enum.map(calendar_events, &ProviderCalendarEventSchema.from_calendar_event/1)

    {:ok, _count} = ProviderCalendarEventQueries.upsert_batch(attrs_list)

    uids = Enum.map(calendar_events, & &1.uid)
    SyncBroadcast.broadcast_cache_update(integration.user_id, uids)

    provider_event_ids = Enum.map(calendar_events, & &1.provider_event_id)

    meetings_by_id =
      MeetingCalendarQueries.list_by_provider_event_ids(integration.id, provider_event_ids)

    Enum.each(calendar_events, &maybe_reconcile_time_change(integration, &1, meetings_by_id))
    :ok
  rescue
    e ->
      Logger.error("Calendar event cache upsert raised an exception",
        calendar_integration_id: integration.id,
        event_count: length(calendar_events),
        reason: Exception.message(e)
      )

      {:error, Exception.message(e)}
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
    case find_meeting(integration_id, provider_event_id, uid) do
      {:ok, meeting} ->
        apply_status_change(meeting, status_for(signal), signal)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Looks up a meeting linked to a calendar event by provider event ID or UID.

  Returns `{:ok, meeting}` if a linked meeting is found, `{:error, :not_found}`
  otherwise. Tries `provider_event_id` first, falls back to `uid`.
  """
  @spec find_meeting(integration_id(), String.t() | nil, String.t() | nil) ::
          {:ok, term()} | {:error, :not_found}
  def find_meeting(integration_id, provider_event_id, uid) do
    cond do
      not is_nil(provider_event_id) ->
        MeetingCalendarQueries.get_by_provider_event_id(integration_id, provider_event_id)

      not is_nil(uid) ->
        MeetingCalendarQueries.get_by_uid_and_integration(integration_id, uid)

      true ->
        {:error, :not_found}
    end
  end

  @spec status_for(signal()) :: String.t()
  defp status_for(:deleted), do: "externally_deleted"
  defp status_for(:modified), do: "externally_modified"

  @spec apply_status_change(term(), String.t(), signal()) :: :ok | {:error, term()}
  defp apply_status_change(meeting, "externally_deleted", :deleted) do
    case MeetingCalendarQueries.update_calendar_sync_status_if_changed(
           meeting.id,
           "externally_deleted"
         ) do
      {:ok, %{} = updated_meeting} ->
        Logger.info("Calendar sync status updated",
          meeting_id: meeting.id,
          signal: :deleted,
          new_status: "externally_deleted"
        )

        # Auto-cancel triggers full notification to both parties.
        # If cancellation fails, revert the sync status so the next
        # reconciliation attempt retries the whole operation.
        case Cancel.execute_external(updated_meeting) do
          {:ok, _cancelled} ->
            :ok

          {:error, reason} ->
            Logger.warning("Auto-cancel failed, reverting sync status for retry",
              meeting_id: meeting.id,
              reason: reason
            )

            case MeetingCalendarQueries.clear_calendar_sync_status(meeting.id) do
              {:ok, _meeting} ->
                :ok

              {:error, revert_reason} ->
                Logger.error("Failed to revert sync status after cancel failure",
                  meeting_id: meeting.id,
                  revert_reason: revert_reason
                )
            end

            {:error, reason}
        end

      {:ok, :already_set} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update calendar sync status",
          meeting_id: meeting.id,
          signal: :deleted,
          error: reason
        )

        {:error, reason}
    end
  end

  defp apply_status_change(meeting, new_status, signal) do
    # Use conditional update to prevent duplicate emails when the same
    # signal arrives twice (e.g., webhook retry or concurrent reconciliation).
    case MeetingCalendarQueries.update_calendar_sync_status_if_changed(meeting.id, new_status) do
      {:ok, %{} = updated_meeting} ->
        Logger.info("Calendar sync status updated",
          meeting_id: meeting.id,
          signal: signal,
          new_status: new_status
        )

        notify_host(updated_meeting, signal)

      {:ok, :already_set} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update calendar sync status",
          meeting_id: meeting.id,
          signal: signal,
          error: reason
        )

        {:error, reason}
    end
  end

  @spec notify_host(term(), signal()) :: :ok
  defp notify_host(meeting, signal) do
    case EmailService.send_external_booking_change(meeting, meeting.organizer_email, signal) do
      {:ok, _result} ->
        Logger.info("External booking change notification sent",
          meeting_id: meeting.id,
          signal: signal
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to send external booking change notification",
          meeting_id: meeting.id,
          reason: reason
        )

        :ok
    end
  end
end
