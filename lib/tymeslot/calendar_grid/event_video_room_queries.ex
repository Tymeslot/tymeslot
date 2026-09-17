defmodule Tymeslot.CalendarGrid.EventVideoRoomQueries do
  @moduledoc """
  Database queries for the video rooms of calendar grid events
  (`Tymeslot.CalendarGrid.EventVideoRoomSchema`), and for the cached calendar
  events that tell whether such a room is still in use.
  """

  import Ecto.Query

  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Repo

  @doc """
  Records a room. A room already recorded for the same video integration is
  left as it is, so a conversation adopted again is never recorded twice.
  """
  @spec insert(map()) :: {:ok, EventVideoRoomSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    attrs
    |> EventVideoRoomSchema.create_changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:video_integration_id, :room_id])
  end

  @doc """
  The room with its video and calendar integrations loaded: the first reaches
  the room on the provider, the second tells whether its event is still there.
  """
  @spec get_with_integrations(pos_integer()) ::
          {:ok, EventVideoRoomSchema.t()} | {:error, :not_found}
  def get_with_integrations(id) do
    query =
      from(r in EventVideoRoomSchema,
        where: r.id == ^id,
        preload: [:video_integration, :calendar_integration]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      room -> {:ok, room}
    end
  end

  @doc """
  The rooms recorded for an event of the calendar integration that any of
  `identifiers` addresses.
  """
  @spec list_for_identifiers(pos_integer(), [String.t()]) :: [EventVideoRoomSchema.t()]
  def list_for_identifiers(_calendar_integration_id, []), do: []

  def list_for_identifiers(calendar_integration_id, identifiers) do
    EventVideoRoomSchema
    |> where([r], r.calendar_integration_id == ^calendar_integration_id)
    |> where([r], r.event_uid in ^identifiers or r.provider_event_id in ^identifiers)
    |> order_by([r], asc: r.id)
    |> Repo.all()
  end

  @doc """
  Records where the calendar provider put an event written under `event_uid`:
  `attrs` carries `:provider_event_id` and `:provider_calendar_id`.
  """
  @spec set_event_location(pos_integer(), String.t(), map()) :: non_neg_integer()
  def set_event_location(calendar_integration_id, event_uid, attrs) do
    {count, _rows} =
      EventVideoRoomSchema
      |> where([r], r.calendar_integration_id == ^calendar_integration_id)
      |> where([r], r.event_uid == ^event_uid)
      |> Repo.update_all(
        set: [
          provider_event_id: attrs.provider_event_id,
          provider_calendar_id: attrs.provider_calendar_id,
          updated_at: now()
        ]
      )

    count
  end

  @doc """
  Sets when a room's lobby opens and when the room stops being needed. A room
  deleted meanwhile is left deleted.
  """
  @spec update_times(EventVideoRoomSchema.t(), DateTime.t() | nil, DateTime.t() | nil) ::
          :ok | :gone
  def update_times(%EventVideoRoomSchema{id: id}, lobby_opens_at, ends_at) do
    {count, _rows} =
      EventVideoRoomSchema
      |> where([r], r.id == ^id)
      |> Repo.update_all(
        set: [lobby_opens_at: lobby_opens_at, ends_at: ends_at, updated_at: now()]
      )

    if count == 1, do: :ok, else: :gone
  end

  @doc """
  Points rooms at the identity their event was given in another calendar
  integration: `identity` carries `:calendar_integration_id`, `:event_uid`,
  `:provider_event_id` and `:provider_calendar_id`.
  """
  @spec move_to_event([pos_integer()], map()) :: non_neg_integer()
  def move_to_event(room_ids, identity) do
    {count, _rows} =
      EventVideoRoomSchema
      |> where([r], r.id in ^room_ids)
      |> Repo.update_all(
        set: [
          calendar_integration_id: identity.calendar_integration_id,
          event_uid: identity.event_uid,
          provider_event_id: identity.provider_event_id,
          provider_calendar_id: identity.provider_calendar_id,
          updated_at: now()
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
  before `ended_before`, with their calendar integration loaded, mirroring
  `MeetingListQueries.list_ended_with_video_room/4`.

  Rooms whose integration is waiting to be reconnected or is being
  disconnected are left out, because every delete through it would be
  refused. A room whose integration link is gone stays in, to be reached
  through the organiser's current integration for the same provider. A room
  with no known end (`ends_at` nil) never falls due.
  """
  @spec list_ended([String.t()], DateTime.t(), DateTime.t(), pos_integer()) ::
          [EventVideoRoomSchema.t()]
  def list_ended(providers, ended_before, ended_after, limit \\ 500) do
    EventVideoRoomSchema
    |> join(:left, [r], vi in assoc(r, :video_integration))
    |> where([r], r.provider in ^providers)
    |> where(
      [r, vi],
      is_nil(r.video_integration_id) or (not vi.needs_reauth and is_nil(vi.deleted_at))
    )
    |> where([r], r.ends_at < ^ended_before and r.ends_at >= ^ended_after)
    |> order_by([r], asc: r.ends_at)
    |> limit(^limit)
    |> preload(:calendar_integration)
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

  @doc """
  The cached calendar events of the calendar integration that `identifiers`
  address, as an event's own row or as a row of one of its occurrences: a row
  whose parent is one of them, or whose uid is one of `series_uids` followed by
  the occurrence suffix CalDAV occurrences are cached under.
  """
  @spec list_cached_events(pos_integer(), [String.t()], [String.t()]) ::
          [ProviderCalendarEventSchema.t()]
  def list_cached_events(_calendar_integration_id, [], []), do: []

  def list_cached_events(calendar_integration_id, identifiers, series_uids) do
    addressed =
      dynamic(
        [e],
        e.uid in ^identifiers or e.provider_event_id in ^identifiers or
          e.recurring_event_id in ^identifiers
      )

    addressed_or_occurrence =
      Enum.reduce(series_uids, addressed, fn uid, acc ->
        dynamic([e], ^acc or like(e.uid, ^(escape_like(uid) <> "\\_%")))
      end)

    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where(^addressed_or_occurrence)
    |> Repo.all()
  end

  defp for_integration(integration_id, scope, %DateTime{} = now) do
    EventVideoRoomSchema
    |> where([r], r.video_integration_id == ^integration_id)
    |> within_scope(scope, now)
  end

  defp within_scope(query, :all, _now), do: query

  defp within_scope(query, :upcoming, now),
    do: where(query, [r], is_nil(r.ends_at) or r.ends_at > ^now)

  defp escape_like(value), do: String.replace(value, ~r/([\\%_])/, "\\\\\\1")

  defp now, do: DateTime.utc_now(:second)
end
