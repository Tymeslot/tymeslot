defmodule Tymeslot.CalendarGrid.EventVideoRoomExpiry do
  @moduledoc """
  Decides whether a calendar grid event's video room has outlived its event
  and may be deleted.

  A room's recorded end can be stale: the event may have been moved, made
  recurring or deleted in a calendar client, where the grid never hears of it.
  Deleting a conversation still in use leaves attendees with a dead join link,
  while keeping one too long only leaves it in the organiser's list, so a room
  is deleted only on positive evidence that its event is over, and kept
  whenever that evidence cannot be had.

  The decision takes two steps.

  `check/1` is the nightly scan's, and reads only the calendar cache, so the
  scan stays cheap:

    * An event still cached that ends later brings the room's times up to
      date, and the room is kept.
    * An event still cached that recurs is kept, with its end widened, or
      cleared when no later end is known, so the scan stops offering it.
    * An event cached as ended, or absent from a calendar that has synced
      successfully since the room fell due, passes on to the job.

  `confirm/1` is the job's, run just before it deletes. It repeats the cache
  check, then asks the calendar provider for the event itself, since the
  cache holds only a year either side of today and only the calendars the
  organiser selected:

    * Found and ending later, or recurring: kept, and the room follows it.
    * Found and still over: deleted.
    * Not found (a 404 or 410, or for Google and Outlook a cancelled event):
      deleted.
    * Any error, timeout or refused credentials: kept, and the next scan asks
      again.
    * A provider that cannot fetch one event (Exchange, and the read-only
      subscription and demo calendars): deleted only when the cache still
      holds the event as ended, and otherwise kept.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.CalendarGrid.EventVideoRoomTimes
  alias Tymeslot.Integrations.Calendar.Operations, as: CalendarOperations

  @seconds_per_day 86_400

  @doc """
  The nightly scan's check, against the calendar cache only. `room` needs its
  calendar integration loaded.
  """
  @spec check(EventVideoRoomSchema.t()) :: :expired | :kept
  def check(%EventVideoRoomSchema{} = room) do
    case cache_verdict(room, cutoff()) do
      :kept -> :kept
      _over -> :expired
    end
  end

  @doc """
  The job's check before it deletes: the cache again, then the calendar
  provider. `room` needs its calendar integration loaded.
  """
  @spec confirm(EventVideoRoomSchema.t()) :: :expired | :kept
  def confirm(%EventVideoRoomSchema{} = room) do
    cutoff = cutoff()

    case cache_verdict(room, cutoff) do
      :kept -> :kept
      verdict -> ask_provider(room, verdict, cutoff)
    end
  end

  # :kept, or why the cache says the event is over: :ended when it still holds
  # the event with a past end, :absent when a synced calendar no longer does.
  defp cache_verdict(%{ends_at: nil}, _cutoff), do: :kept

  defp cache_verdict(room, cutoff) do
    cond do
      not DateTime.before?(room.ends_at, cutoff) -> :kept
      is_nil(room.calendar_integration) -> :kept
      true -> cached_event_verdict(room, cutoff)
    end
  end

  defp cached_event_verdict(room, cutoff) do
    case EventVideoRoomQueries.list_cached_events(
           room.calendar_integration_id,
           room_identifiers(room),
           [room.event_uid]
         ) do
      [] ->
        if synced_since_due?(room), do: :absent, else: :kept

      events ->
        case judge(room, events, cutoff) do
          :over -> :ended
          :kept -> :kept
        end
    end
  end

  defp ask_provider(room, verdict, cutoff) do
    event_ref = %{
      uid: room.event_uid,
      provider_event_id: room.provider_event_id,
      calendar_id: room.provider_calendar_id
    }

    case CalendarOperations.fetch_event(event_ref, {room.calendar_integration_id, room.user_id}) do
      {:error, :not_found} ->
        :expired

      {:ok, [_event | _more] = events} ->
        if judge(room, events, cutoff) == :over, do: :expired, else: :kept

      {:error, :unsupported} when verdict == :ended ->
        :expired

      other ->
        Logger.info("Could not confirm a calendar event is over, keeping its video room",
          calendar_event_video_room_id: room.id,
          outcome: describe(other)
        )

        :kept
    end
  end

  # Updates the room from `events` (the event's cached rows or the provider's
  # answer) unless they show it over.
  defp judge(room, events, cutoff) do
    current = {room.lobby_opens_at, room.ends_at}

    if Enum.any?(events, &EventVideoRoomTimes.recurring?/1) do
      {lobby, ends} = widen(current, events)
      ends = if ends && DateTime.after?(ends, cutoff), do: ends
      EventVideoRooms.apply_times(room, {lobby, ends})
      :kept
    else
      case latest_one_off(events) do
        # Nothing to judge the event by.
        nil ->
          :kept

        {lobby, ends} ->
          if DateTime.before?(ends, cutoff) do
            :over
          else
            EventVideoRooms.apply_times(
              room,
              EventVideoRoomTimes.merge(current, {:exact, lobby, ends})
            )

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

  defp synced_since_due?(%{
         calendar_integration: %{last_external_sync_at: %DateTime{} = synced_at},
         ends_at: ends_at
       }),
       do: DateTime.after?(synced_at, DateTime.add(ends_at, retention_seconds(), :second))

  defp synced_since_due?(_room), do: false

  defp room_identifiers(room),
    do:
      [room.event_uid, room.provider_event_id]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -retention_seconds(), :second)

  # Read at run time: `config/runtime.exs` sets it from the environment.
  defp retention_seconds,
    do: Application.fetch_env!(:tymeslot, :video_room_retention_days) * @seconds_per_day

  defp describe({:ok, []}), do: :no_usable_event
  defp describe({:error, reason}) when is_atom(reason), do: reason
  defp describe({:error, _reason}), do: :error
  defp describe(_other), do: :unexpected
end
