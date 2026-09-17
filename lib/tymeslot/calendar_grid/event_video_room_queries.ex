defmodule Tymeslot.CalendarGrid.EventVideoRoomQueries do
  @moduledoc """
  Database queries for the video rooms of calendar grid events
  (`Tymeslot.CalendarGrid.EventVideoRoomSchema`).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Repo

  @doc """
  Records a room.
  """
  @spec insert(map()) :: {:ok, EventVideoRoomSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs), do: attrs |> EventVideoRoomSchema.create_changeset() |> Repo.insert()

  @doc """
  The room with its video integration loaded, which is what reaching the room
  on the provider needs.
  """
  @spec get_with_integration(pos_integer()) ::
          {:ok, EventVideoRoomSchema.t()} | {:error, :not_found}
  def get_with_integration(id) do
    query = from(r in EventVideoRoomSchema, where: r.id == ^id, preload: :video_integration)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      room -> {:ok, room}
    end
  end

  @doc """
  The rooms recorded for one calendar event.
  """
  @spec list_for_event(pos_integer(), String.t()) :: [EventVideoRoomSchema.t()]
  def list_for_event(calendar_integration_id, event_uid) do
    EventVideoRoomSchema
    |> where([r], r.calendar_integration_id == ^calendar_integration_id)
    |> where([r], r.event_uid == ^event_uid)
    |> order_by([r], asc: r.id)
    |> Repo.all()
  end

  @doc """
  Sets when a room's event starts and ends.
  """
  @spec update_schedule(EventVideoRoomSchema.t(), DateTime.t() | nil, DateTime.t() | nil) ::
          {:ok, EventVideoRoomSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_schedule(%EventVideoRoomSchema{} = room, starts_at, ends_at) do
    room
    |> Changeset.change(starts_at: starts_at, ends_at: ends_at)
    |> Repo.update()
  end

  @doc """
  Points every room of one calendar event at the event's new identity, after
  the event moved to another calendar integration and was given a new uid
  there. Returns how many rooms moved.
  """
  @spec move_to_event(pos_integer(), String.t(), pos_integer(), String.t()) :: non_neg_integer()
  def move_to_event(from_integration_id, from_uid, to_integration_id, to_uid) do
    {count, _rows} =
      EventVideoRoomSchema
      |> where([r], r.calendar_integration_id == ^from_integration_id)
      |> where([r], r.event_uid == ^from_uid)
      |> Repo.update_all(
        set: [
          calendar_integration_id: to_integration_id,
          event_uid: to_uid,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    count
  end

  @doc """
  Removes a room's record. Removing one already gone is not an error.
  """
  @spec delete(EventVideoRoomSchema.t()) :: :ok
  def delete(%EventVideoRoomSchema{id: id}) do
    {_count, _rows} = EventVideoRoomSchema |> where([r], r.id == ^id) |> Repo.delete_all()
    :ok
  end

  @doc """
  Rooms on one of `providers` whose event ended at or after `ended_after` and
  before `ended_before`, mirroring `MeetingListQueries.list_ended_with_video_room/4`.

  Rooms whose integration is waiting to be reconnected or is being disconnected
  are left out, because every delete through it would be refused. A series with
  no end (`ends_at` nil) never falls due.
  """
  @spec list_ended([String.t()], DateTime.t(), DateTime.t(), pos_integer()) ::
          [EventVideoRoomSchema.t()]
  def list_ended(providers, ended_before, ended_after, limit \\ 500) do
    EventVideoRoomSchema
    |> join(:inner, [r], vi in assoc(r, :video_integration))
    |> where([_r, vi], vi.provider in ^providers)
    |> where([_r, vi], not vi.needs_reauth and is_nil(vi.deleted_at))
    |> where([r], r.ends_at < ^ended_before and r.ends_at >= ^ended_after)
    |> order_by([r], asc: r.ends_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Up to `limit` rooms made through the given integration, within `scope` (see
  `MeetingListQueries.with_video_room_for_integration/3`). `:upcoming` keeps to
  rooms whose event has not ended by `now`.
  """
  @spec list_for_integration(
          pos_integer(),
          MeetingListQueries.room_scope(),
          DateTime.t(),
          pos_integer()
        ) :: [EventVideoRoomSchema.t()]
  def list_for_integration(integration_id, scope, now, limit) do
    integration_id
    |> for_integration(scope, now)
    |> order_by([r], asc: r.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  How many rooms `list_for_integration/4` covers, without a limit.
  """
  @spec count_for_integration(pos_integer(), MeetingListQueries.room_scope(), DateTime.t()) ::
          non_neg_integer()
  def count_for_integration(integration_id, scope, now) do
    integration_id
    |> for_integration(scope, now)
    |> Repo.aggregate(:count, :id)
  end

  defp for_integration(integration_id, scope, %DateTime{} = now) do
    EventVideoRoomSchema
    |> where([r], r.video_integration_id == ^integration_id)
    |> within_scope(scope, now)
  end

  defp within_scope(query, :all, _now), do: query

  defp within_scope(query, :upcoming, now),
    do: where(query, [r], is_nil(r.ends_at) or r.ends_at > ^now)
end
