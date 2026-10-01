defmodule Tymeslot.CalendarGrid.EventVideoRooms do
  @moduledoc """
  Keeps track of the video rooms made for events created on the dashboard
  calendar grid, so the rooms that would otherwise stay on the organiser's
  server for ever are deleted, and never one still in use.

  A booking's room is held by its `meetings` row, which every clean-up path
  works from. A grid event lives only in the organiser's calendar, so the room
  is recorded here when it is made, for the providers whose rooms have to
  follow their event (`ProviderConfig.rooms_recorded_for_grid_events/0`):

    * A room that persists until something deletes it
      (`ProviderConfig.rooms_deleted_after_meeting/0`, Nextcloud Talk).
      `Tymeslot.Workers.ExpiredVideoRoomCleanupWorker` deletes it some days
      after its event has ended, once the calendar confirms it
      (`Tymeslot.CalendarGrid.EventVideoRoomExpiry`), and disconnecting the
      integration with its rooms deletes it too.
    * A room that is an event of its own in the organiser's calendar
      (`ProviderConfig.room_held_as_calendar_event?/1`): the separate Outlook
      event a Teams meeting gets when it cannot be attached to the grid event
      itself. Its join link does not name that event, so the record is the only
      way back to it. It is an ordinary meeting once its time has passed, so
      neither the nightly clean-up nor a disconnect deletes it.

  The record follows the event through the grid: moving the event moves the
  record's times, and the room's lobby, or its event, with them; splitting a
  series for an edit of one occurrence and every following one moves the
  record to the series the following occurrences now live in, and moving a
  whole series to another calendar moves the record with it;
  replacing the event's video, deleting a one-off event, or deleting a whole
  series deletes the room.

  A Teams meeting attached to the grid event itself is never recorded. Its
  room id is the event's own Outlook id, so it moves and goes with the event
  through the calendar, and deleting it as a room would delete the event.

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
    * Replacing the video of one occurrence, deleting a whole series, or
      a series found deleted in a calendar client, leaves the room while
      another cached event of the organiser's calendars still carries its
      link (`link_holder/3`), such as the earlier half of a split series,
      wherever it moved.
    * The times a room keeps only ever widen for a series
      (`Tymeslot.CalendarGrid.EventVideoRoomTimes`).
    * Before an ended room is deleted, the cached calendar is consulted, since
      the event may have been moved or made recurring outside the grid.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.CalendarGrid.EventVideoRoomExpiry
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.CalendarGrid.EventVideoRoomTimes
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Workers.VideoSyncWorker

  # Google instance ids and CalDAV occurrence uids: the series id followed by
  # the occurrence's start, as a date or a local or UTC date-time.
  @occurrence_suffix ~r/_\d{8}(T\d{6}Z?)?\z/

  @doc """
  Records a room just made for a grid event, when its provider is one whose
  rooms follow their event (`ProviderConfig.rooms_recorded_for_grid_events/0`)
  and the room is not the event itself.

  `event` carries `:user_id`, `:video_integration_id`,
  `:calendar_integration_id`, `:uid`, optionally `:provider_event_id`, and the
  event's timing and recurrence (see `EventVideoRoomTimes.for_event/1`).
  """
  @spec record(map(), map()) :: :ok
  # A Teams meeting attached to the event: its room id is the event's own
  # Outlook id (see the moduledoc).
  def record(%{room_data: %{room_id: event_id}}, %{provider_event_id: event_id}), do: :ok

  def record(%{provider_type: provider, room_data: %{room_id: room_id}}, event)
      when is_binary(room_id) and room_id != "" do
    provider = Atom.to_string(provider)

    if provider in ProviderConfig.rooms_recorded_for_grid_events() do
      insert(provider, room_id, event)
    else
      :ok
    end
  end

  def record(_meeting_context, _event), do: :ok

  @doc """
  Records where the calendar provider put an event written under the uid
  Tymeslot generated: the identifier it returned, which is how Google and
  Outlook address the event from then on, the calendar it was written to,
  which Google needs to look the event up again, and the iCalendar UID its
  cached row carries, which Outlook finds it by once it moved to another
  calendar.
  """
  @spec identified(
          pos_integer(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  def identified(calendar_integration_id, event_uid, provider_uid, provider_calendar_id, ical_uid)
      when is_integer(calendar_integration_id) and is_binary(event_uid) do
    _count =
      EventVideoRoomQueries.set_event_location(calendar_integration_id, event_uid, %{
        provider_event_id: other_identifier(provider_uid, event_uid),
        provider_calendar_id: provider_calendar_id,
        event_ical_uid: ical_uid
      })

    :ok
  end

  def identified(_integration_id, _event_uid, _provider_uid, _calendar_id, _ical_uid), do: :ok

  @doc """
  Brings the rooms of a grid event in step with its timing after the event
  changed, and moves each room's lobby, or its event, when it moved.
  """
  @spec rescheduled(map()) :: :ok
  def rescheduled(event) do
    times = EventVideoRoomTimes.for_event(event)

    event
    |> rooms_of_event()
    |> Enum.filter(&follows_timing?(&1, event, times))
    |> Enum.each(
      &apply_times(&1, EventVideoRoomTimes.merge({&1.lobby_opens_at, &1.ends_at}, times))
    )
  end

  # A room held as a calendar event of its own carries one meeting's start and
  # end, which only a one-off timed event gives it: a series' times only ever
  # widen, and an all-day event's are whole days. Such a room is left where
  # it is rather than stretched over them.
  defp follows_timing?(room, event, {mode, _lobby, _ends}) do
    not ProviderConfig.room_held_as_calendar_event?(room.provider) or
      (mode == :exact and Map.get(event, :all_day) != true)
  end

  @doc """
  Follows a one-off grid event that moved to another calendar integration,
  where it was created afresh under `new_uid` and the provider returned
  `provider_uid`, in `provider_calendar_id`. An occurrence moved out of its series leaves the room with
  the series.
  """
  @spec moved(map(), pos_integer(), String.t(), String.t() | nil, String.t() | nil) :: :ok
  def moved(event, to_integration_id, new_uid, provider_uid, provider_calendar_id) do
    case one_off_rooms(event) do
      [] ->
        :ok

      rooms ->
        _count =
          EventVideoRoomQueries.move_to_event(Enum.map(rooms, & &1.id), %{
            calendar_integration_id: to_integration_id,
            event_uid: new_uid,
            provider_event_id: other_identifier(provider_uid, new_uid),
            provider_calendar_id: provider_calendar_id,
            # Learnt afresh from the destination's cache.
            event_ical_uid: nil
          })

        :ok
    end
  end

  @doc """
  Follows a series that was split in two at one of its occurrences,
  addressed from any one of its rows: the occurrences from there on now live
  in a new series, `tail_uid`, which the provider addresses as `tail_id` (a
  CalDAV resource's href, a Google or Outlook event's id), and carry the
  series' join link with them. The series' rooms move to the new series,
  since its occurrences are the last the rooms serve: they are found from
  its rows, follow them when they move, go when it is deleted as a whole,
  and are judged over only once it is. The original series keeps the
  occurrences before the split, which all come earlier, and the same join
  link: deleting the new series as a whole hands the rooms back to it
  (`series_deleted/1`).
  """
  @spec series_split(map(), String.t(), String.t()) :: :ok
  def series_split(event, tail_uid, tail_id),
    do:
      series_moved(
        event,
        event.calendar_integration_id,
        tail_uid,
        tail_id,
        Map.get(event, :provider_calendar_id)
      )

  @doc """
  Follows a whole series moved to another calendar, addressed from any one
  of its rows on the calendar it left: it now lives on the integration
  `to_integration_id`, in `provider_calendar_id`, as the series `new_uid`,
  which the provider addresses as `new_id` (a CalDAV resource's href, a
  Google or Outlook event's id). Every occurrence carries the series' join
  link in the description the move copied, so the series' rooms go with
  them. Unlike `moved/5`, which leaves the rooms of an occurrence with its
  series, this takes the rooms whatever the row looks like.
  """
  @spec series_moved(map(), pos_integer(), String.t(), String.t(), String.t() | nil) :: :ok
  def series_moved(event, to_integration_id, new_uid, new_id, provider_calendar_id) do
    case rooms_for(event, true) do
      [] ->
        :ok

      rooms ->
        _count =
          EventVideoRoomQueries.move_to_event(Enum.map(rooms, & &1.id), %{
            calendar_integration_id: to_integration_id,
            event_uid: new_uid,
            provider_event_id: other_identifier(new_id, new_uid),
            provider_calendar_id: provider_calendar_id,
            # A series' uid is its iCalendar UID on every provider.
            event_ical_uid: new_uid
          })

        :ok
    end
  end

  # The provider's own identifier for an event, when it is not the uid the
  # event was written under.
  defp other_identifier(provider_uid, event_uid)
       when is_binary(provider_uid) and provider_uid != event_uid,
       do: provider_uid

  defp other_identifier(_provider_uid, _event_uid), do: nil

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
  Deletes the rooms of a series that was deleted as a whole, addressed from
  any one of its rows. Unlike `event_deleted/1`, the series' rooms go whatever
  the row looks like: a CalDAV occurrence edited on its own carries no repeat
  rule, yet still shares its series' rooms.

  A room another event still uses is kept: when a cached event of the
  organiser's calendars outside the series carries the series' join link
  (see `link_holder/3`), the series' rooms move to that event, or to its series,
  as if they had been recorded for it. This is how the earlier half of a
  split series keeps the room its later half took with it
  (`series_split/3`) when the later half is deleted, and loses it when it is
  deleted in turn. The series' own rows never count, cached or not.
  """
  @spec series_deleted(map()) :: :ok
  def series_deleted(event) do
    case rooms_for(event, true) do
      [] ->
        :ok

      [%{user_id: user_id} | _more] = rooms ->
        own = event_identifiers(event)
        series = Enum.map(own, &series_identifier/1)

        case find_holder(user_id, event, series_links(event), Enum.uniq(own ++ series), series) do
          nil -> discard(rooms)
          holder -> adopt(rooms, holder)
        end
    end
  end

  @doc """
  A cached event of any of the user `user_id`'s calendars, other than
  `event` itself, that still carries one of the join links `links`: as its
  cached video link, or in its description, which the calendar keeps while
  the cached link waits for `Tymeslot.Workers.SeriesVideoWorker` after a
  series-wide write. The other occurrences of `event`'s series count, and so
  does an event on another calendar integration, where a series moved there
  keeps its link. `nil` when there is none.

  The description is read here only to keep a room, never to find one to
  delete (see the moduledoc).
  """
  @spec link_holder(pos_integer(), map(), [String.t() | nil]) :: map() | nil
  def link_holder(user_id, event, links), do: find_holder(user_id, event, links, [event.uid], [])

  @doc """
  Hands `room`, whose event is gone from its calendar, to another cached
  event still carrying the join link the room was last seen under (see
  `link_holder/3`), as if it had been recorded for that event, or its series:
  the earlier half of a split series whose later half was deleted in a
  calendar client, for one. `:none` when no event carries it, or the link was
  never learnt, and the room is the caller's to delete.

  The room is not judged gone again until the nightly scan has seen it under
  its new event.
  """
  @spec hand_to_link_holder(EventVideoRoomSchema.t()) :: :handed | :none
  def hand_to_link_holder(%EventVideoRoomSchema{calendar_integration_id: integration_id} = room)
      when is_integer(integration_id) do
    case EventVideoRoomQueries.find_link_holder(
           room.user_id,
           room.calendar_integration_id,
           non_blank([room.join_link]),
           cached_identifiers(room),
           [room.event_uid]
         ) do
      nil ->
        :none

      holder ->
        adopt([room], holder)
        :handed
    end
  end

  def hand_to_link_holder(%EventVideoRoomSchema{}), do: :none

  defp find_holder(
         user_id,
         %{calendar_integration_id: calendar_integration_id},
         links,
         own,
         series_uids
       )
       when is_integer(user_id) and is_integer(calendar_integration_id),
       do:
         EventVideoRoomQueries.find_link_holder(
           user_id,
           calendar_integration_id,
           non_blank(links),
           own,
           series_uids
         )

  defp find_holder(_user_id, _event, _links, _own, _series_uids), do: nil

  # The join links a series' rows carry: the cached one, and any in the
  # description, which is all a row cached before its video was carried back
  # has (see `link_holder/3`).
  defp series_links(event),
    do: [Map.get(event, :video_link) | EventVideo.join_links(Map.get(event, :description))]

  # Points `rooms` at the event still carrying their link, or at its series,
  # by the identifiers every row of it matches (see `rooms_for/2`): the uid
  # without an occurrence's suffix, and the series' address. The event has not
  # been seen under that identity yet, so its iCalendar UID is learnt afresh.
  defp adopt(rooms, holder) do
    event_uid = series_identifier(holder.uid)

    provider_id =
      case Occurrence.series_address(holder) do
        {:ok, {_kind, id}} -> id
        {:error, :unaddressable_series} -> holder.provider_event_id
      end

    _count =
      EventVideoRoomQueries.move_to_event(Enum.map(rooms, & &1.id), %{
        calendar_integration_id: holder.calendar_integration_id,
        event_uid: event_uid,
        provider_event_id: other_identifier(provider_id, event_uid),
        provider_calendar_id: holder.provider_calendar_id,
        event_ical_uid: nil
      })

    Logger.info("Video room kept: another calendar event still uses it",
      calendar_integration_id: holder.calendar_integration_id,
      calendar_event_video_room_ids: Enum.map(rooms, & &1.id)
    )
  end

  @doc """
  The recorded rooms of `event` (or of its series) made on the video
  integration `video_integration_id`.
  """
  @spec rooms_on_integration(map(), pos_integer() | nil) :: [EventVideoRoomSchema.t()]
  def rooms_on_integration(event, video_integration_id) when is_integer(video_integration_id) do
    event
    |> rooms_of_event()
    |> Enum.filter(&(&1.video_integration_id == video_integration_id))
  end

  def rooms_on_integration(_event, _video_integration_id), do: []

  @doc """
  The recorded rooms of `event`'s series (or of `event` itself, if it is not
  part of one), unscoped by video integration. For
  `Tymeslot.CalendarGrid.SeriesCarry` alone, which does not yet know which
  integration a series' room belongs to when its currently cached rows have
  lost track of the video (a sync that outran the carry).
  """
  @spec rooms_of_series(map()) :: [EventVideoRoomSchema.t()]
  def rooms_of_series(event), do: rooms_of_event(event)

  @doc """
  Deletes `rooms`, which their event no longer uses, through
  `Tymeslot.Workers.VideoSyncWorker`, which removes each record once its room
  is gone.
  """
  @spec discard([EventVideoRoomSchema.t()]) :: :ok
  def discard(rooms), do: Enum.each(rooms, &enqueue(&1, "delete"))

  @doc """
  The identifiers a room's event may be cached under: the uid Tymeslot
  generated, the provider's own identifier, and the iCalendar UID its cached
  row was seen with.
  """
  @spec cached_identifiers(EventVideoRoomSchema.t()) :: [String.t()]
  def cached_identifiers(room),
    do: non_blank([room.event_uid, room.provider_event_id, room.event_ical_uid])

  @doc """
  What addresses a room's event on its calendar provider
  (`Tymeslot.Integrations.Calendar.Provider.event_ref/0`).
  """
  @spec provider_event_ref(EventVideoRoomSchema.t()) :: map()
  def provider_event_ref(room),
    do: %{
      uid: room.event_uid,
      provider_event_id: room.provider_event_id,
      calendar_id: room.provider_calendar_id,
      ical_uid: room.event_ical_uid
    }

  @doc """
  Whether an ended room's event is over in its calendar's cache. The nightly
  scan's check; see `EventVideoRoomExpiry.check/1`.
  """
  @spec check_expired(EventVideoRoomSchema.t()) :: :expired | :kept
  defdelegate check_expired(room), to: EventVideoRoomExpiry, as: :check

  @doc """
  Whether an ended room may be deleted now, asking its calendar provider
  before trusting the cache. The job's check; see
  `EventVideoRoomExpiry.confirm/1`.
  """
  @spec confirm_expired(EventVideoRoomSchema.t()) :: :expired | :kept
  defdelegate confirm_expired(room), to: EventVideoRoomExpiry, as: :confirm

  defp insert(provider, room_id, event) do
    {lobby_opens_at, ends_at} =
      event |> EventVideoRoomTimes.for_event() |> EventVideoRoomTimes.initial()

    attrs = %{
      user_id: event.user_id,
      video_integration_id: event.video_integration_id,
      provider: provider,
      calendar_integration_id: event.calendar_integration_id,
      event_uid: event.uid,
      provider_event_id: other_identifier(Map.get(event, :provider_event_id), event.uid),
      provider_calendar_id: Map.get(event, :provider_calendar_id),
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
          errors: LogFormat.reason(changeset.errors)
        )

        :ok
    end
  end

  @doc """
  Sets a room's lobby time and end, and queues the room to move when what it
  follows changed: its lobby time, or for a room held as a calendar event of
  its own, its start or end. A room deleted meanwhile is left deleted.
  """
  @spec apply_times(EventVideoRoomSchema.t(), {DateTime.t() | nil, DateTime.t() | nil}) :: :ok
  def apply_times(%{lobby_opens_at: lobby, ends_at: ends}, {lobby, ends}), do: :ok

  def apply_times(room, {lobby, ends}) do
    case EventVideoRoomQueries.update_times(room, lobby, ends) do
      :ok -> maybe_move_room(room, {lobby, ends})
      # Deleted meanwhile, by a delete job or a disconnect: nothing to follow.
      :gone -> :ok
    end
  end

  defp maybe_move_room(room, {lobby, ends}) do
    if moves?(room, lobby, ends), do: enqueue(room, "update"), else: :ok
  end

  # Reached only once the times changed. A room held as a calendar event of
  # its own follows its start and end, and needs both; any other follows its
  # lobby time alone.
  defp moves?(_room, nil, _ends), do: false

  defp moves?(room, lobby, ends) do
    if ProviderConfig.room_held_as_calendar_event?(room.provider),
      do: ends != nil,
      else: lobby != room.lobby_opens_at
  end

  defp enqueue(room, action) do
    case VideoSyncWorker.enqueue_event_room(room.id, action) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue video room sync for a calendar event",
          calendar_event_video_room_id: room.id,
          action: action,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  # The rooms of the series an event belongs to, or of the event itself.
  defp rooms_of_event(event), do: rooms_for(event, EventVideoRoomTimes.recurring?(event))

  defp rooms_for(%{calendar_integration_id: calendar_integration_id} = event, series?)
       when is_integer(calendar_integration_id) do
    identifiers = event_identifiers(event)

    identifiers =
      if series?,
        do: Enum.uniq(identifiers ++ Enum.map(identifiers, &series_identifier/1)),
        else: identifiers

    EventVideoRoomQueries.list_for_identifiers(calendar_integration_id, identifiers)
  end

  defp rooms_for(_event, _series?), do: []

  defp one_off_rooms(event) do
    if EventVideoRoomTimes.recurring?(event), do: [], else: rooms_of_event(event)
  end

  defp event_identifiers(event) do
    [:uid, :provider_event_id, :recurring_event_id]
    |> Enum.map(&Map.get(event, &1))
    |> non_blank()
  end

  defp series_identifier(identifier), do: String.replace(identifier, @occurrence_suffix, "")

  defp non_blank(values),
    do: values |> Enum.filter(&(is_binary(&1) and String.trim(&1) != "")) |> Enum.uniq()
end
