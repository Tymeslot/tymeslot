defmodule Tymeslot.CalendarGrid.EventVideoRoomPresence do
  @moduledoc """
  Decides whether a calendar grid event's video room has lost its event,
  because the event was deleted in a calendar client rather than through the
  grid, which deletes the room itself (`EventVideoRooms.event_deleted/1`).
  A whole series can only ever be deleted that way.

  This is independent of the room's end, which
  `Tymeslot.CalendarGrid.EventVideoRoomExpiry` judges: an endless series'
  Talk conversation never ends, and a separate Teams event must outlive its
  meeting's end and go only with its grid event.

  Deleting a room still in use kills a live meeting's join link, so absence
  from the calendar cache is never evidence on its own. The cache holds only
  the calendars the organiser selected and a year either side of today, and
  an Outlook event moved to another calendar is cached under a new id. The
  decision takes two steps.

  `check/1` is the nightly scan's, and reads only the calendar cache:

    * An event found in the cache (its own row or an occurrence's) is marked
      seen, with the iCalendar UID its own row carries, and the room is kept.
      Finding it again restarts the clock.
    * An event never seen is kept: it may not be synced yet, or live where
      the cache does not reach.
    * An event seen, then absent from a calendar that has synced successfully
      more than 48 hours after it was last seen, passes on to the job.

  `confirm/1` is the job's, run just before it deletes. It repeats the cache
  check, then asks the calendar provider:

    * Not found (a 404 or 410, or for Google and Outlook a cancelled event;
      Outlook also looks the event up by its iCalendar UID across the
      mailbox's calendars, since a move changes its id): gone.
    * Found: kept, and marked seen, so it is not asked again for a while.
    * Any error, timeout, refused credentials, or a provider that cannot
      fetch one event: kept, and the next scan asks again.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.Integrations.Calendar.Operations, as: CalendarOperations
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig

  @grace_seconds 48 * 3600
  @seconds_per_day 86_400

  @doc """
  The nightly scan: the recorded rooms whose event the calendar cache says is
  gone, for the job to confirm. Rooms whose event ended before the cache's
  window are not looked for, since they are absent from it either way.
  """
  @spec list_gone() :: [EventVideoRoomSchema.t()]
  def list_gone do
    cache_reaches_back_to =
      DateTime.add(
        DateTime.utc_now(),
        -CalendarProviderConfig.sync_window_past_days() * @seconds_per_day,
        :second
      )

    ProviderConfig.rooms_recorded_for_grid_events()
    |> EventVideoRoomQueries.list_watched(cache_reaches_back_to)
    |> Enum.filter(&(check(&1) == :gone))
  end

  @doc """
  The nightly scan's check of one room, against the calendar cache only.
  `room` needs its calendar integration loaded.
  """
  @spec check(EventVideoRoomSchema.t()) :: :gone | :kept
  def check(%EventVideoRoomSchema{} = room) do
    case cache_verdict(room) do
      :absent -> :gone
      :kept -> :kept
    end
  end

  @doc """
  The job's check before it deletes: the cache again, then the calendar
  provider. `room` needs its calendar integration loaded.
  """
  @spec confirm(EventVideoRoomSchema.t()) :: :gone | :kept
  def confirm(%EventVideoRoomSchema{} = room) do
    case cache_verdict(room) do
      :absent -> ask_provider(room)
      :kept -> :kept
    end
  end

  defp cache_verdict(%{calendar_integration: nil}), do: :kept

  defp cache_verdict(room) do
    identifiers = EventVideoRooms.cached_identifiers(room)

    case EventVideoRoomQueries.list_cached_events(
           room.calendar_integration_id,
           identifiers,
           [room.event_uid]
         ) do
      [] ->
        if absent_long_enough?(room), do: :absent, else: :kept

      events ->
        EventVideoRoomQueries.mark_seen(room, now(), learnt_ical_uid(room, events, identifiers))
        :kept
    end
  end

  # Seen once, and missing from every successful sync for the grace period
  # since. A calendar whose sync keeps failing never gets that far.
  defp absent_long_enough?(%{
         event_seen_at: %DateTime{} = seen_at,
         calendar_integration: %{last_external_sync_at: %DateTime{} = synced_at}
       }),
       do: DateTime.after?(synced_at, DateTime.add(seen_at, @grace_seconds, :second))

  defp absent_long_enough?(_room), do: false

  # The uid of the event's own cached row, not an occurrence's, learnt once.
  defp learnt_ical_uid(%{event_ical_uid: nil}, events, identifiers) do
    Enum.find_value(events, fn event ->
      if event.uid in identifiers or event.provider_event_id in identifiers, do: event.uid
    end)
  end

  defp learnt_ical_uid(_room, _events, _identifiers), do: nil

  defp ask_provider(room) do
    case CalendarOperations.fetch_event(
           EventVideoRooms.provider_event_ref(room),
           {room.calendar_integration_id, room.user_id}
         ) do
      {:error, :not_found} ->
        :gone

      {:ok, [_event | _more]} ->
        # Alive where the cache does not reach.
        EventVideoRoomQueries.mark_seen(room, now(), nil)
        :kept

      other ->
        Logger.info("Could not confirm a calendar event is gone, keeping its video room",
          calendar_event_video_room_id: room.id,
          outcome: describe(other)
        )

        :kept
    end
  end

  defp now, do: DateTime.utc_now(:second)

  defp describe({:ok, []}), do: :no_usable_event
  defp describe({:error, reason}) when is_atom(reason), do: reason
  defp describe(_other), do: :error
end
