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
      seen, with the iCalendar UID its own row carries and the join link the
      event carries, and the room is kept. Finding it again restarts the clock.
    * An event never seen is kept: it may not be synced yet, or live where
      the cache does not reach.
    * An event seen, then absent from a calendar that has synced successfully
      more than 48 hours after it was last seen, passes on to the job.

  `confirm/1` is the job's, run just before it deletes. It repeats the cache
  check, then asks the calendar provider:

    * Not found (a 404 or 410, or for Google and Outlook a cancelled event)
      in every calendar of the organiser's account, those the organiser did
      not select included, since the event may have moved to one of them
      (`Provider.find_moved_event/2`; Outlook looks it up by its iCalendar
      UID across the mailbox, since a move changes its id): gone, unless another
      cached event of the organiser's calendars still carries the join link
      the event was seen with, such as the earlier half of a split series.
      The room is then handed to that event
      (`EventVideoRooms.hand_to_link_holder/1`) and kept.
    * Found: kept, and marked seen, so it is not asked again for a while.
    * Any error, timeout, refused credentials, or a provider that cannot
      fetch one event: kept, and the next scan asks again.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideo
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
      :absent -> room |> ask_provider() |> unless_held_elsewhere(room)
      :kept -> :kept
    end
  end

  defp unless_held_elsewhere(:gone, room) do
    case EventVideoRooms.hand_to_link_holder(room) do
      :handed -> :kept
      :none -> :gone
    end
  end

  defp unless_held_elsewhere(:kept, _room), do: :kept

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
        EventVideoRoomQueries.mark_seen(
          room,
          now(),
          learnt_ical_uid(room, events, identifiers),
          learnt_join_link(room, events, identifiers)
        )

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

  # The join link the event carries, learnt once: its own row's before the
  # occurrences', and the cached link before the one in the description,
  # which is all a row has while its cached link waits for
  # `Tymeslot.Workers.SeriesVideoWorker`. Only cached links of the room's own
  # video integration count, and among the occurrences the link most of them
  # carry, so that an occurrence given a video of its own cannot lend the
  # room its link. It is only ever used to keep the room
  # (`EventVideoRooms.hand_to_link_holder/1`), which a wrong link would let
  # go while still in use.
  defp learnt_join_link(%{join_link: nil} = room, events, identifiers) do
    {own, occurrences} =
      Enum.split_with(events, &(&1.uid in identifiers or &1.provider_event_id in identifiers))

    cached_link = &room_link(&1, room.video_integration_id)
    described_link = &(&1.description |> EventVideo.join_links() |> List.first())

    Enum.find_value(own, cached_link) || most_common(occurrences, cached_link) ||
      Enum.find_value(own, described_link) || most_common(occurrences, described_link)
  end

  defp learnt_join_link(_room, _events, _identifiers), do: nil

  defp room_link(%{video_link: link, video_integration_id: video_id}, video_id)
       when is_binary(link) and link != "" and is_integer(video_id),
       do: link

  defp room_link(_row, _video_integration_id), do: nil

  defp most_common(rows, link_of) do
    rows
    |> Enum.map(link_of)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_link, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp ask_provider(room) do
    case CalendarOperations.fetch_event(
           EventVideoRooms.provider_event_ref(room),
           {room.calendar_integration_id, room.user_id}
         ) do
      {:error, :not_found} ->
        :gone

      {:ok, [_event | _more]} ->
        # Alive where the cache does not reach.
        EventVideoRoomQueries.mark_seen(room, now())
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
