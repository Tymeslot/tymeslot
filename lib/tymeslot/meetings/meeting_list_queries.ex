defmodule Tymeslot.Meetings.MeetingListQueries do
  @moduledoc """
  Listing, filtering, and pagination queries for the Meeting schema.

  Holds the read-side query surface — the composable query-building DSL
  (filter by user/status/time, keyset cursor, ordering) and the public
  list/pagination functions built on top of it. Single-record lookups,
  writes, and aggregate counts live in `Tymeslot.Meetings.MeetingQueries`;
  this module is purely about returning lists of meetings.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  # Query building helpers

  defp for_user_email(query, email),
    do: from(m in query, where: m.organizer_email == ^email or m.attendee_email == ^email)

  defp with_status(query, nil), do: query
  defp with_status(query, status), do: from(m in query, where: m.status == ^status)

  defp without_status(query, nil), do: query
  defp without_status(query, ""), do: query

  defp without_status(query, status) when is_list(status),
    do: from(m in query, where: m.status not in ^status)

  defp without_status(query, status), do: from(m in query, where: m.status != ^status)

  defp upcoming(query, now), do: from(m in query, where: m.end_time > ^now)
  defp past(query, now), do: from(m in query, where: m.end_time < ^now)
  defp order_by_start_asc(query), do: from(m in query, order_by: [asc: m.start_time])

  defp apply_limit(query, limit), do: from(m in query, limit: ^limit)

  defp apply_time_filter(query, nil, _now), do: query
  defp apply_time_filter(query, :upcoming, now), do: upcoming(query, now)
  defp apply_time_filter(query, :past, now), do: past(query, now)

  defp cursor_after(query, nil, _after_id), do: query
  defp cursor_after(query, _after_start, nil), do: query

  defp cursor_after(query, after_start, after_id) do
    from(m in query,
      where:
        m.start_time < ^after_start or
          (m.start_time == ^after_start and m.id < ^after_id)
    )
  end

  defp order_by_start_desc_id_desc(query),
    do: from(m in query, order_by: [desc: m.start_time, desc: m.id])

  @doc """
  Returns upcoming meetings that should have a video room link but do not.
  """
  @spec list_meetings_missing_video_rooms(DateTime.t(), pos_integer()) :: [Meeting.t()]
  def list_meetings_missing_video_rooms(now, limit \\ 500) do
    now
    |> meetings_missing_video_rooms_base()
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns the given user's upcoming meetings that should have a video room link
  but do not. Used to retry video room creation immediately after the user
  re-authorises their video provider integration with the right scope.
  """
  @spec list_user_meetings_missing_video_rooms(pos_integer(), DateTime.t(), pos_integer()) ::
          [Meeting.t()]
  def list_user_meetings_missing_video_rooms(user_id, now, limit \\ 500) do
    now
    |> meetings_missing_video_rooms_base()
    |> where([m], m.organizer_user_id == ^user_id)
    |> limit(^limit)
    |> Repo.all()
  end

  @typedoc """
  Which of an integration's rooms a disconnect deletes: those of upcoming live
  bookings, or every room the integration still holds.
  """
  @type room_scope :: :upcoming | :all

  @doc """
  Builds the query for meetings that still hold a provider-side room created by
  the given integration, within `scope`.

  `:upcoming` keeps to live bookings that have not ended by `now`: past
  bookings are history, and most providers' rooms expire on their own. `:all`
  takes every meeting, whatever its time or status, for providers whose rooms
  stay on the organiser's server until something deletes them.

  Shared by the list and the count, so what the disconnect modal offers to
  delete is exactly what the disconnect deletes.
  """
  @spec with_video_room_for_integration(pos_integer(), room_scope(), DateTime.t()) ::
          Ecto.Query.t()
  def with_video_room_for_integration(integration_id, scope, %DateTime{} = now) do
    Meeting
    |> where([m], m.video_integration_id == ^integration_id)
    |> where([m], not is_nil(m.video_room_id))
    |> within_room_scope(scope, now)
  end

  defp within_room_scope(query, :all, _now), do: query

  defp within_room_scope(query, :upcoming, now),
    do: query |> MeetingState.where_live_booking() |> upcoming(now)

  @doc """
  Returns up to `limit` meetings holding a provider-side room created by the
  given integration, within `scope` (see `with_video_room_for_integration/3`).

  Used when a user disconnects an integration and asks for the rooms to be
  deleted along with it.
  """
  @spec list_with_video_room_for_integration(
          pos_integer(),
          room_scope(),
          DateTime.t(),
          pos_integer()
        ) :: [Meeting.t()]
  def list_with_video_room_for_integration(integration_id, scope, now, limit) do
    integration_id
    |> with_video_room_for_integration(scope, now)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns the id and status of up to `limit` meetings holding a provider-side
  room created by the given integration that have not ended by `now`, soonest
  first, whatever their status.

  Used to bring each room in line with its booking once the integration is
  reconnected, since changes made while it could not reach the provider were
  dropped: the room of a live booking is updated, and the room of a released
  one deleted. Ended meetings are left to the clean-up jobs.
  """
  @spec list_upcoming_video_rooms_for_integration(pos_integer(), DateTime.t(), pos_integer()) ::
          [%{id: String.t(), status: String.t()}]
  def list_upcoming_video_rooms_for_integration(integration_id, %DateTime{} = now, limit) do
    Meeting
    |> where([m], m.video_integration_id == ^integration_id)
    |> where([m], not is_nil(m.video_room_id))
    |> upcoming(now)
    |> order_by([m], asc: m.start_time)
    |> limit(^limit)
    |> select([m], %{id: m.id, status: m.status})
    |> Repo.all()
  end

  @doc """
  Returns cancelled meetings that still hold a provider-side room.

  Successful provider deletion clears `video_room_id`, so a cancelled meeting
  that still carries one has not been cleaned up: either it predates that
  behaviour, or its integration was disconnected before the release that
  resolves a fallback. `cancelled_before` keeps the scan clear of bookings whose
  cancellation job is still in flight.
  """
  @spec list_cancelled_with_video_room(DateTime.t(), pos_integer()) :: [Meeting.t()]
  def list_cancelled_with_video_room(cancelled_before, limit \\ 200) do
    Meeting
    |> where([m], m.status == "cancelled")
    |> where([m], not is_nil(m.video_room_id))
    |> where([m], m.cancelled_at < ^cancelled_before)
    |> order_by([m], asc: m.cancelled_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Meetings whose video room still exists on one of `providers` and whose end
  lies at or after `ended_after` and before `ended_before`.

  `ended_after` bounds how far back the scan reaches. A room nothing can reach
  any more, because its integration was disconnected and never replaced, drops
  out of the window instead of being retried every night for ever.

  Cancelled meetings are left out: `list_cancelled_with_video_room/2` covers
  them, so no room is picked up by both scans. So are meetings whose
  integration is waiting to be reconnected or is being disconnected, because
  every delete through it would be refused. A meeting whose integration link is
  gone stays in: `Tymeslot.Integrations.Video.IntegrationResolver` falls back on
  the organiser's current integration for the same provider.
  """
  @spec list_ended_with_video_room([String.t()], DateTime.t(), DateTime.t(), pos_integer()) ::
          [Meeting.t()]
  def list_ended_with_video_room(providers, ended_before, ended_after, limit \\ 500) do
    Meeting
    |> join(:left, [m], vi in assoc(m, :video_integration))
    |> where([m], m.video_provider in ^providers)
    |> where([m], not is_nil(m.video_room_id))
    |> where([m], m.status != "cancelled")
    |> where(
      [m, vi],
      is_nil(m.video_integration_id) or (not vi.needs_reauth and is_nil(vi.deleted_at))
    )
    |> where([m], m.end_time < ^ended_before and m.end_time >= ^ended_after)
    |> order_by([m], asc: m.end_time)
    |> limit(^limit)
    |> Repo.all()
  end

  defp meetings_missing_video_rooms_base(now) do
    Meeting
    |> MeetingState.where_live_booking()
    |> upcoming(now)
    |> where([m], not is_nil(m.video_integration_id))
    |> where([m], is_nil(m.video_room_id))
    |> order_by([m], asc: m.start_time)
  end

  @doc """
  Get upcoming meetings for a specific user with limit.
  Filters by user email as either organizer or attendee.
  """
  @spec upcoming_meetings_for_user(String.t(), non_neg_integer()) :: [Meeting.t()]
  def upcoming_meetings_for_user(user_email, limit) do
    now = DateTime.utc_now()

    Meeting
    |> MeetingState.where_live_booking()
    |> upcoming(now)
    |> for_user_email(user_email)
    |> order_by_start_asc()
    |> apply_limit(limit)
    |> Repo.all()
  end

  @doc """
  Returns the organiser's live bookings overlapping the `[from_utc, to_utc)`
  window, ordered by start time.

  "Live" means the slot currently occupies the calendar: an occupying status
  and not voided by a pending reschedule request. Past bookings inside the
  window are included — the calendar grid shows history as well as what is
  ahead.
  """
  @spec list_for_organizer_in_range(pos_integer(), DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def list_for_organizer_in_range(organizer_user_id, %DateTime{} = from_utc, %DateTime{} = to_utc) do
    Meeting
    |> MeetingState.where_slot_live()
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.start_time < ^to_utc and m.end_time > ^from_utc)
    |> order_by_start_asc()
    |> Repo.all()
  end

  @doc """
  Get upcoming meetings for a specific user with proper database filtering.
  Replaces the N+1 pattern of loading all meetings and filtering in memory.
  """
  @spec list_upcoming_meetings_for_user(String.t()) :: [Meeting.t()]
  def list_upcoming_meetings_for_user(user_email) do
    now = DateTime.utc_now()

    Meeting
    |> for_user_email(user_email)
    |> upcoming(now)
    |> order_by_start_asc()
    |> Repo.all()
  end

  @doc """
  Cursor-based pagination for a user's meetings using keyset on start_time and id.
  Accepts opts: :after_start (DateTime), :after_id (binary_id), :per_page, :status, :time_filter (:upcoming | :past).
  Returns a list limited to per_page.
  """
  @spec list_meetings_for_user_paginated_cursor(String.t(), Keyword.t()) :: [Meeting.t()]
  def list_meetings_for_user_paginated_cursor(user_email, opts) do
    after_start = Keyword.get(opts, :after_start)
    after_id = Keyword.get(opts, :after_id)
    per_page = Keyword.get(opts, :per_page, 20)
    # Fetch one extra item to determine if there's a next page
    limit = per_page + 1
    status = Keyword.get(opts, :status)
    exclude_status = Keyword.get(opts, :exclude_status)
    time_filter = Keyword.get(opts, :time_filter)

    now = DateTime.utc_now()

    Meeting
    |> for_user_email(user_email)
    |> with_status(status)
    |> without_status(exclude_status)
    |> apply_time_filter(time_filter, now)
    |> order_by_start_desc_id_desc()
    |> cursor_after(after_start, after_id)
    |> apply_limit(limit)
    |> preload(:guests)
    |> Repo.all()
  end
end
