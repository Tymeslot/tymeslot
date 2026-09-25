defmodule Tymeslot.Meetings.CalendarEventCache do
  @moduledoc """
  Keeps the local cache of provider calendar events (`provider_calendar_event`)
  in step with the writes `Tymeslot.Meetings.CalendarEventSync` makes to a
  meeting's event, rather than waiting for the next inbound sync to notice.
  """

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Meetings.CalendarEventLink
  require Logger

  @doc """
  Writes an outbound update of `meeting`'s event, already pushed to the
  provider as `event_data`, through to the local cache.

  Always returns `:ok`; see the comment below.
  """
  # Keeps the cache row (and any live calendar-grid viewers subscribed via
  # PubSub) in sync with a Tymeslot-initiated change, instead of waiting on
  # the next inbound sync cycle to notice the drift.
  #
  # The inbound counterpart is
  # `Tymeslot.Integrations.Calendar.Sync.post_commit_reconciliation/2`, and the
  # availability-cache invalidation is here for the reason it is there, in the
  # same order: Exchange answers availability out of this very table
  # (`Exchange.Provider.list_events/2` is a cache read), so a row this function
  # moves has to drop the slots that were computed from where it used to be
  # before anyone reacts to the broadcast.
  #
  # Never fails the update, and that has to hold for a raise as much as for an
  # error tuple: the provider push has already landed, so letting an exception
  # out would have the worker retry a write that succeeded. The next inbound
  # sync reconciles the row either way.
  @spec write_through_update(map(), map()) :: :ok
  def write_through_update(meeting, event_data) do
    with {:ok, cached_event} <- find_cached_event(meeting),
         {:ok, _updated} <- update_cached_event(cached_event, event_data) do
      AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)
      SyncBroadcast.broadcast_cache_update(meeting.organizer_user_id, [cached_event.uid])
    else
      {:error, :not_found} ->
        # No cache row yet — e.g. this is the very first outbound push and no
        # inbound sync has cached the event. Nothing stale to correct.
        :ok

      {:error, reason} ->
        log_write_through_failure(meeting, reason)
    end
  rescue
    error -> log_write_through_failure(meeting, error)
  end

  @doc """
  Drops the cached copy of `event_id`, an event of `meeting`'s calendar that
  was deleted on the provider, so the grid stops showing it.
  """
  @spec forget(map(), String.t()) :: :ok
  def forget(%{calendar_integration_id: integration_id} = meeting, event_id)
      when is_integer(integration_id) do
    ProviderCalendarEventQueries.delete_by_provider_event_ids(integration_id, [event_id])
    AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)
    SyncBroadcast.broadcast_cache_update(meeting.organizer_user_id, [])
    :ok
  end

  def forget(_meeting, _event_id), do: :ok

  defp log_write_through_failure(meeting, reason) do
    Logger.warning("Failed to write through outbound calendar update to local cache",
      meeting_id: meeting.id,
      reason: inspect(reason)
    )

    :ok
  end

  # `CalendarEventLink` is this project's one rule for "this cached provider
  # event is that meeting": the two match when they share any non-blank
  # identifier, within a single integration. Going through it rather than
  # hand-rolling a lookup order matters here specifically, because the grid
  # dedup this write-through exists to correct
  # (`CalendarGrid.BookingEvents.list_for_range/4`) links the two sides by that
  # same rule — so any narrower rule here would silently fail to update exactly
  # the rows the grid had already decided were linked.
  defp find_cached_event(meeting) do
    ProviderCalendarEventQueries.get_by_identifiers(
      meeting.calendar_integration_id,
      CalendarEventLink.identifiers(meeting)
    )
  end

  # `status` and `transparency` belong here because the push carries them and
  # they are not always the same as last time: approving a pending booking
  # flips its event TENTATIVE → CONFIRMED through this very "update" action
  # (`Tymeslot.Meetings.Approval`), and `show_as_free` decides whether the row
  # blocks time at all (`CalendarEvent.blocking?/1`). Writing the new times
  # while leaving those two behind produced a row that looked freshly synced
  # and still claimed the old status.
  #
  # `timezone` is left out for the opposite reason: `event_data.timezone` is
  # the booker's display zone, not the event's TZID, and `ICalBuilder` emits
  # UTC with no TZID at all — so writing it invents a value the provider never
  # reports back and the next inbound sync clears again.
  defp update_cached_event(cached_event, event_data) do
    attrs = %{
      start_at: event_data.start_time,
      end_at: event_data.end_time,
      summary: event_data.summary,
      description: event_data.description,
      location: event_data.location,
      status: Atom.to_string(event_data.status),
      transparency: Atom.to_string(event_data.transparency)
    }

    ProviderCalendarEventQueries.update_after_outbound_push(cached_event, attrs)
  end
end
