defmodule Tymeslot.Integrations.Calendar.CalDAV.EventProcessor do
  @moduledoc """
  Handles CalDAV event upserts and deletions against the calendar event cache.

  Separates event processing logic from the sync-tier orchestration in
  `SyncCalDavCalendarWorker`.
  """

  alias Tymeslot.DatabaseQueries.CalendarEventCacheQueries
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  @doc """
  Upserts a list of events into the calendar event cache and triggers
  time-change reconciliation for any event linked to a meeting.
  """
  @spec process_events(integration :: map(), events :: [map()]) :: :ok
  def process_events(integration, events) do
    Enum.each(events, fn event -> process_event(integration, event) end)
  end

  @doc """
  Deletes cached events by their server-relative `href` and notifies the sync
  reconciler of each deletion.
  """
  @spec process_deletions(integration :: map(), hrefs :: [String.t()]) :: :ok
  def process_deletions(integration, hrefs) do
    Enum.each(hrefs, fn href -> process_deletion(integration, href) end)
  end

  @doc """
  Parses a raw iCalendar string and returns the first event found.
  """
  @spec parse_ical_from_string(String.t() | term()) ::
          {:ok, map()} | {:error, :no_events | :empty_data | term()}
  def parse_ical_from_string(ical_string) when is_binary(ical_string) and ical_string != "" do
    case ICalParser.parse(ical_string) do
      {:ok, [event | _rest]} -> {:ok, event}
      {:ok, []} -> {:error, :no_events}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_ical_from_string(_other), do: {:error, :empty_data}

  @doc """
  Strips surrounding whitespace and double-quotes from an etag value.
  """
  @spec clean_etag(String.t() | term()) :: String.t() | nil
  def clean_etag(etag) when is_binary(etag) do
    etag |> String.trim() |> String.trim("\"")
  end

  def clean_etag(_other), do: nil

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp process_event(integration, event) do
    attrs = build_cache_attrs(integration.id, event)

    :ok = CalendarEventCacheQueries.upsert_batch([attrs])
    SyncBroadcast.broadcast_cache_update(integration.user_id, [attrs.uid])
    maybe_reconcile_time_change(integration, event)
  end

  defp process_deletion(integration, href) do
    CalendarEventCacheQueries.delete_by_provider_event_id(integration.id, href)
    Sync.reconcile(integration.id, href, nil, :deleted)
  end

  defp maybe_reconcile_time_change(integration, event) do
    uid = Map.get(event, :uid)
    href = Map.get(event, :href)
    provider_event_id = href || uid

    case MeetingQueries.get_by_provider_event_id(integration.id, provider_event_id) do
      {:ok, meeting} ->
        event_start = normalise_start_time(Map.get(event, :start_time))

        if time_changed?(meeting.start_time, event_start) do
          Sync.reconcile(integration.id, provider_event_id, uid, :modified)
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp time_changed?(_meeting_time, nil), do: false

  defp time_changed?(meeting_time, event_start) do
    DateTime.compare(
      DateTime.truncate(meeting_time, :second),
      DateTime.truncate(event_start, :second)
    ) != :eq
  end

  defp build_cache_attrs(integration_id, event) do
    uid = Map.get(event, :uid)
    href = Map.get(event, :href)
    raw_start = Map.get(event, :start_time)
    raw_end = Map.get(event, :end_time)
    start_time = normalise_start_time(raw_start)
    end_time = normalise_end_time(raw_end)

    %{
      uid: uid,
      calendar_integration_id: integration_id,
      # CalDAV provider_event_id is the event's href (server-relative URL)
      provider_event_id: href || uid,
      title: Map.get(event, :summary),
      start_at: start_time,
      end_at: end_time,
      all_day: all_day?(raw_start, raw_end),
      location: Map.get(event, :location),
      description: Map.get(event, :description),
      attendees: Map.get(event, :attendees, []),
      recurrence_rule: Map.get(event, :recurrence_rule),
      recurring_event_id: Map.get(event, :recurrence_id),
      status: if(Map.get(event, :transparency) == "transparent", do: "free", else: "confirmed"),
      raw_data: event,
      etag: Map.get(event, :etag),
      synced_at: DateTime.utc_now(:second)
    }
  end

  # ICalParser returns start_time/end_time as either a DateTime or a Date
  # (for all-day events). Normalise both to DateTime for the cache schema.

  defp normalise_start_time(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp normalise_start_time(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp normalise_start_time(_other), do: nil

  defp normalise_end_time(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp normalise_end_time(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp normalise_end_time(_other), do: nil

  # Proper all-day: iCal VALUE=DATE — parser returns %Date{}
  defp all_day?(%Date{}, _end_time), do: true

  # Radicale (and some other CalDAV servers) write whole-day blocks as UTC midnight
  # DateTimes rather than VALUE=DATE properties. Detect this: both endpoints must be
  # exactly midnight UTC, which can only happen for intentional day-boundary events.
  defp all_day?(
         %DateTime{hour: 0, minute: 0, second: 0, time_zone: "Etc/UTC"},
         %DateTime{hour: 0, minute: 0, second: 0, time_zone: "Etc/UTC"}
       ),
       do: true

  defp all_day?(_start_time, _end_time), do: false
end
