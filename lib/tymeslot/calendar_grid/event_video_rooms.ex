defmodule Tymeslot.CalendarGrid.EventVideoRooms do
  @moduledoc """
  Keeps track of the video rooms made for events created on the dashboard
  calendar grid, so the rooms that would otherwise stay on the organiser's
  server for ever are deleted, and never one still in use.

  A booking's room is held by its `meetings` row, which every clean-up path
  works from. A grid event lives only in the organiser's calendar, so for a
  provider whose rooms persist until something deletes them
  (`ProviderConfig.rooms_deleted_after_meeting/0`) the room is recorded here
  when it is made. The record follows the event through the grid: moving the
  event moves the record's times, and the room's lobby with them; deleting a
  one-off event deletes the room. `Tymeslot.Workers.ExpiredVideoRoomCleanupWorker`
  deletes rooms some days after their event has ended, once the calendar
  confirms it (`check_expired/1`), and disconnecting the integration with its
  rooms deletes them too.

  ## Which event a room belongs to

  The room is never read back out of the event's description or location. The
  organiser can edit that text in any calendar client, and a room found there
  need not be one Tymeslot created.

  Instead the record holds the event's identifiers within its calendar
  integration, and matches an event that shares any of them, as
  `Tymeslot.Meetings.CalendarEventLink` does for bookings: the uid Tymeslot
  generated, which CalDAV servers keep, and the identifier the provider
  returned, which Google and Outlook cache as `provider_event_id`. Occurrences
  of a series are matched too: Google and Outlook cache them with their
  parent's id in `recurring_event_id`, and CalDAV under the series uid followed
  by `_` and the occurrence's start.

  ## Erring towards keeping a room

  A conversation deleted while still in use leaves attendees with a dead join
  link; one kept too long only lingers in the organiser's list. So a room is
  deleted only when its event is known to be over:

    * Deleting an occurrence of a series, or moving one to another calendar,
      leaves the room with the series.
    * The times a room keeps only ever widen for a series
      (`Tymeslot.CalendarGrid.EventVideoRoomTimes`).
    * Before an ended room is deleted, the cached calendar is consulted, since
      the event may have been moved or made recurring outside the grid.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.CalendarGrid.EventVideoRoomTimes
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Workers.VideoSyncWorker

  @seconds_per_day 86_400

  # Google instance ids and CalDAV occurrence uids: the series id followed by
  # the occurrence's start, as a date or a local or UTC date-time.
  @occurrence_suffix ~r/_\d{8}(T\d{6}Z?)?\z/

  @doc """
  Records a room just made for a grid event, when its provider is one whose
  rooms Tymeslot deletes.

  `event` carries `:user_id`, `:video_integration_id`,
  `:calendar_integration_id`, `:uid`, optionally `:provider_event_id`, and the
  event's timing and recurrence (see `EventVideoRoomTimes.for_event/1`).
  """
  @spec record(map(), map()) :: :ok
  def record(%{provider_type: provider, room_data: %{room_id: room_id}}, event)
      when is_binary(room_id) and room_id != "" do
    provider = Atom.to_string(provider)

    if provider in ProviderConfig.rooms_deleted_after_meeting() do
      insert(provider, room_id, event)
    else
      :ok
    end
  end

  def record(_meeting_context, _event), do: :ok

  @doc """
  Records the identifier the calendar provider returned for an event written
  under the uid Tymeslot generated, which is how Google and Outlook address it
  from then on.
  """
  @spec identified(pos_integer(), String.t(), String.t() | nil) :: :ok
  def identified(calendar_integration_id, event_uid, provider_uid)
      when is_integer(calendar_integration_id) and is_binary(event_uid) and
             is_binary(provider_uid) and provider_uid != event_uid do
    _count =
      EventVideoRoomQueries.set_provider_event_id(
        calendar_integration_id,
        event_uid,
        provider_uid
      )

    :ok
  end

  def identified(_calendar_integration_id, _event_uid, _provider_uid), do: :ok

  @doc """
  Brings the rooms of a grid event in step with its timing after the event
  changed, and moves each room's lobby when it moved.
  """
  @spec rescheduled(map()) :: :ok
  def rescheduled(event) do
    times = EventVideoRoomTimes.for_event(event)

    event
    |> rooms_of_event()
    |> Enum.each(
      &apply_times(&1, EventVideoRoomTimes.merge({&1.lobby_opens_at, &1.ends_at}, times))
    )
  end

  @doc """
  Follows a one-off grid event that moved to another calendar integration,
  where it was created afresh under `new_uid` and the provider returned
  `provider_uid`. An occurrence moved out of its series leaves the room with
  the series.
  """
  @spec moved(map(), pos_integer(), String.t(), String.t() | nil) :: :ok
  def moved(event, to_integration_id, new_uid, provider_uid) do
    case one_off_rooms(event) do
      [] ->
        :ok

      rooms ->
        provider_event_id = if provider_uid != new_uid, do: provider_uid
        ids = Enum.map(rooms, & &1.id)

        _count =
          EventVideoRoomQueries.move_to_event(ids, to_integration_id, new_uid, provider_event_id)

        :ok
    end
  end

  @doc """
  Deletes the rooms of a one-off grid event that was deleted. The provider
  calls run in `Tymeslot.Workers.VideoSyncWorker`, which removes each record
  once its room is gone. Deleting an occurrence of a series leaves the room,
  which the rest of the series still uses.
  """
  @spec event_deleted(map()) :: :ok
  def event_deleted(event) do
    event
    |> one_off_rooms()
    |> Enum.each(&enqueue(&1, "delete"))
  end

  @doc """
  Whether a room whose recorded end is past the retention period
  (`VIDEO_ROOM_RETENTION_DAYS`) may be deleted.

  Its event is looked up in the calendar cache first, because it may have
  changed outside the grid:

    * An event still cached that ends later brings the room's times up to
      date, and the room is kept.
    * An event still cached that recurs is kept, with its end widened, or
      cleared when no later end is known, so the nightly scan stops offering
      it.
    * An event no longer cached is only taken as deleted once its calendar has
      synced successfully since the room fell due. Without that, and whenever
      the room's calendar integration is gone, the room is kept.

  `room` needs its calendar integration loaded.
  """
  @spec check_expired(EventVideoRoomSchema.t()) :: :expired | :kept
  def check_expired(%EventVideoRoomSchema{ends_at: nil}), do: :kept

  def check_expired(%EventVideoRoomSchema{} = room) do
    retention_seconds = retention_days() * @seconds_per_day
    cutoff = DateTime.add(DateTime.utc_now(), -retention_seconds, :second)

    cond do
      not DateTime.before?(room.ends_at, cutoff) -> :kept
      is_nil(room.calendar_integration) -> :kept
      true -> check_against_calendar(room, cutoff, retention_seconds)
    end
  end

  defp check_against_calendar(room, cutoff, retention_seconds) do
    identifiers = room_identifiers(room)

    case EventVideoRoomQueries.list_cached_events(
           room.calendar_integration_id,
           identifiers,
           [room.event_uid]
         ) do
      [] ->
        if synced_since?(room.calendar_integration, room.ends_at, retention_seconds),
          do: :expired,
          else: :kept

      events ->
        check_cached_events(room, events, cutoff)
    end
  end

  defp check_cached_events(room, events, cutoff) do
    current = {room.lobby_opens_at, room.ends_at}

    if Enum.any?(events, &EventVideoRoomTimes.recurring?/1) do
      {lobby, ends} = widen(current, events)
      ends = if ends && DateTime.after?(ends, cutoff), do: ends
      apply_times(room, {lobby, ends})
      :kept
    else
      case latest_one_off(events) do
        # No cached copy has a time to judge by.
        nil ->
          :kept

        {lobby, ends} ->
          if DateTime.before?(ends, cutoff) do
            :expired
          else
            apply_times(room, EventVideoRoomTimes.merge(current, {:exact, lobby, ends}))
            :kept
          end
      end
    end
  end

  defp widen(current, events) do
    Enum.reduce(events, current, fn event, acc ->
      {_mode, lobby, ends} = EventVideoRoomTimes.for_event(event)
      EventVideoRoomTimes.merge(acc, {:series, lobby, ends})
    end)
  end

  # A one-off event cached more than once (its own row and a stale copy) is
  # judged by the latest of them.
  defp latest_one_off(events) do
    events
    |> Enum.map(&EventVideoRoomTimes.for_event/1)
    |> Enum.flat_map(fn
      {_mode, _lobby, nil} -> []
      {_mode, lobby, ends} -> [{lobby, ends}]
    end)
    |> Enum.max_by(fn {_lobby, ends} -> ends end, DateTime, fn -> nil end)
  end

  defp synced_since?(
         %{last_external_sync_at: %DateTime{} = synced_at},
         ends_at,
         retention_seconds
       ),
       do: DateTime.after?(synced_at, DateTime.add(ends_at, retention_seconds, :second))

  defp synced_since?(_calendar_integration, _ends_at, _retention_seconds), do: false

  # Read at run time: `config/runtime.exs` sets it from the environment.
  defp retention_days, do: Application.fetch_env!(:tymeslot, :video_room_retention_days)

  defp insert(provider, room_id, event) do
    {lobby_opens_at, ends_at} =
      event |> EventVideoRoomTimes.for_event() |> EventVideoRoomTimes.initial()

    attrs = %{
      user_id: event.user_id,
      video_integration_id: event.video_integration_id,
      provider: provider,
      calendar_integration_id: event.calendar_integration_id,
      event_uid: event.uid,
      provider_event_id: provider_event_id(event),
      room_id: room_id,
      lobby_opens_at: lobby_opens_at,
      ends_at: ends_at
    }

    case EventVideoRoomQueries.insert(attrs) do
      {:ok, _room} ->
        :ok

      {:error, changeset} ->
        # The room exists either way; failing the event the user just created
        # over its bookkeeping would be worse than a room left to its owner.
        Logger.warning("Failed to record the video room of a calendar event",
          user_id: event.user_id,
          video_integration_id: event.video_integration_id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp provider_event_id(%{uid: uid, provider_event_id: id}) when is_binary(id) and id != uid,
    do: id

  defp provider_event_id(_event), do: nil

  defp apply_times(%{lobby_opens_at: lobby, ends_at: ends}, {lobby, ends}), do: :ok

  defp apply_times(room, {lobby, ends}) do
    case EventVideoRoomQueries.update_times(room, lobby, ends) do
      :ok -> maybe_move_lobby(room, lobby)
      # Deleted meanwhile, by a delete job or a disconnect: nothing to follow.
      :gone -> :ok
    end
  end

  defp maybe_move_lobby(%{lobby_opens_at: same}, same), do: :ok
  defp maybe_move_lobby(_room, nil), do: :ok
  defp maybe_move_lobby(room, _lobby), do: enqueue(room, "update")

  defp enqueue(room, action) do
    case VideoSyncWorker.enqueue_event_room(room.id, action) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue video room sync for a calendar event",
          calendar_event_video_room_id: room.id,
          action: action,
          reason: inspect(reason)
        )

        :ok
    end
  end

  # The rooms of the series an event belongs to, or of the event itself.
  defp rooms_of_event(%{calendar_integration_id: calendar_integration_id} = event)
       when is_integer(calendar_integration_id) do
    identifiers = event_identifiers(event)

    identifiers =
      if EventVideoRoomTimes.recurring?(event),
        do: Enum.uniq(identifiers ++ Enum.map(identifiers, &series_identifier/1)),
        else: identifiers

    EventVideoRoomQueries.list_for_identifiers(calendar_integration_id, identifiers)
  end

  defp rooms_of_event(_event), do: []

  defp one_off_rooms(event) do
    if EventVideoRoomTimes.recurring?(event), do: [], else: rooms_of_event(event)
  end

  defp event_identifiers(event) do
    [:uid, :provider_event_id, :recurring_event_id]
    |> Enum.map(&Map.get(event, &1))
    |> non_blank()
  end

  defp room_identifiers(room), do: non_blank([room.event_uid, room.provider_event_id])

  defp series_identifier(identifier), do: String.replace(identifier, @occurrence_suffix, "")

  defp non_blank(values),
    do: values |> Enum.filter(&(is_binary(&1) and String.trim(&1) != "")) |> Enum.uniq()
end
