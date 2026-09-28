defmodule Tymeslot.Integrations.Calendar.Google.CacheSweep do
  @moduledoc """
  Removes the cached events of a Google calendar that a complete listing of
  it no longer returns.

  Google reports a deletion as a `cancelled` entry only in a sync-token
  delta. The windowed listings the sync also makes, every secondary calendar
  on every run and the booking calendar's bootstrap and requested runs,
  return what exists and nothing about what has gone, so an event deleted in
  Google stayed in the cache (grid, agenda, search, reminders, the free/busy
  feed) until the prune dropped it long after it ended. Each occurrence of a
  series is cached under its original start (`EventNormaliser.cache_uid/1`),
  so a series retimed in Google showed every occurrence twice, old and new.

  A delta is not a complete listing, and nobody has confirmed that it
  cancels the old instances of a series retimed in Google. So each series a
  booking calendar's delta names has its instances listed in full as well,
  and that listing sweeps the series' own rows alone: one request per
  changed series, however many of its occurrences changed.

  After such a listing, a row of that calendar is swept when all of these
  hold:

    * **it overlaps the listed window inset by a day at each edge.** Google
      lists an event whose end is after `timeMin` and whose start is before
      `timeMax`, the overlap `ProviderCalendarEventQueries` applies too. The
      day's inset keeps a row straddling an edge, where an all-day event's
      dates, read in the calendar's zone by Google and as dates here, could
      fall either side of it, and absorbs the moment between computing the
      window here and in the listing.
    * **nothing has written it since the run began**, neither the sync (every
      row a listing returned in this run is rewritten, whichever of the
      integration's calendars returned it) nor the calendar grid, whose
      creates, edits and restored series land in the cache after Google has
      them, and may land after the listing was read. This is why a row is
      judged by when it was last written rather than by whether its uid is in
      the listing: a uid difference would sweep a grid write racing the
      listing, and a row still filed under the calendar an event moved out
      of while another calendar's listing returns it.
    * **it holds no local change waiting for the server** (`sync_state`).
      Google has no offline queue today; the guard costs nothing and keeps a
      queued write from being swept if it ever gets one.
    * **it is not linked to a Tymeslot booking.** A row's absence from a
      listing is weaker evidence than Google reporting the event cancelled,
      and a booking's event is the one row whose loss means something beyond
      the cache. The sweep neither cancels the meeting nor emails anyone, as
      `Sync.reconcile_deletions/3` would, and it keeps the meeting's row so
      the two stay consistent; an explicit cancellation still retires both.

  Only rows are deleted. A video room recorded for a swept event is left to
  `Tymeslot.CalendarGrid.EventVideoRoomPresence`, which deletes one only
  after 48 hours unseen and Google confirming the event gone.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarSweepQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Meetings

  @edge_inset_days 1

  @typedoc """
  One calendar a complete listing read, and the window it read; or, with a
  master's id, the complete listing of that recurring event's instances in
  the calendar, which is swept of that series' rows alone.
  """
  @type listed ::
          {calendar_id :: String.t(), {DateTime.t(), DateTime.t()}}
          | {calendar_id :: String.t(), {DateTime.t(), DateTime.t()}, master_id :: String.t()}

  @doc """
  The window a windowed listing started at `now` reads: the configured sync
  window either side of it.
  """
  @spec listing_window(DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def listing_window(now) do
    {DateTime.add(now, -ProviderConfig.sync_window_past_days(), :day),
     DateTime.add(now, ProviderConfig.sync_window_future_days(), :day)}
  end

  @doc """
  Sweeps each calendar in `listed`, whose complete listings the run begun
  at `run_started_at` read and cached, of the rows those listings no longer
  returned. Always `:ok`; a failure is logged, and the next run sweeps again.
  """
  @spec sweep(CalendarIntegrationSchema.t(), [listed()], DateTime.t()) :: :ok
  def sweep(%CalendarIntegrationSchema{} = integration, listed, run_started_at) do
    swept = Enum.flat_map(listed, &sweep_calendar(integration, &1, run_started_at))

    if swept != [] do
      Sync.invalidate_cache_for_user(integration)
      SyncBroadcast.broadcast_cache_update(integration.user_id, swept)
    end

    :ok
  rescue
    error ->
      Logger.error("Google Calendar sweep of events gone from a listing failed",
        calendar_integration_id: integration.id,
        error: Exception.message(error)
      )

      :ok
  end

  defp sweep_calendar(integration, {calendar_id, window}, run_started_at),
    do: sweep_calendar(integration, {calendar_id, window, nil}, run_started_at)

  defp sweep_calendar(
         integration,
         {calendar_id, {window_start, window_end}, series},
         run_started_at
       ) do
    range_start = DateTime.add(window_start, @edge_inset_days, :day)
    range_end = DateTime.add(window_end, -@edge_inset_days, :day)

    ids =
      integration.id
      |> ProviderCalendarSweepQueries.list_candidates(
        calendar_id,
        range_start,
        range_end,
        run_started_at,
        series
      )
      |> reject_booking_rows(integration)
      |> Enum.map(& &1.id)

    swept =
      ProviderCalendarSweepQueries.delete_candidates(
        integration.id,
        calendar_id,
        ids,
        run_started_at
      )

    if swept != [] do
      Logger.info("Google Calendar sweep removed events gone from a complete listing",
        calendar_integration_id: integration.id,
        calendar_id: calendar_id,
        swept_count: length(swept)
      )
    end

    swept
  end

  defp reject_booking_rows([], _integration), do: []

  defp reject_booking_rows(candidates, integration) do
    identifiers = candidates |> Meetings.calendar_identifier_set() |> MapSet.to_list()

    case Meetings.list_meetings_by_calendar_identifiers(integration.id, identifiers) do
      none when map_size(none) == 0 ->
        candidates

      meetings_by_identifier ->
        Enum.reject(candidates, fn candidate ->
          candidate
          |> Meetings.calendar_event_identifiers()
          |> Enum.any?(&Map.has_key?(meetings_by_identifier, &1))
        end)
    end
  end
end
