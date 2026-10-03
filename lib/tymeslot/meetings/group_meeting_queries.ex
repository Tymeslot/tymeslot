defmodule Tymeslot.Meetings.GroupMeetingQueries do
  @moduledoc """
  Database queries for group meetings: meetings that hold seats for multiple
  participants (meeting types with `max_participants > 1`).

  A group slot is always exactly one live meeting row per
  `(meeting_type_id, start_time)`; these queries locate that row for seat
  booking and for the availability seat overlay.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Repo

  @doc """
  Fetches the live group meeting for a meeting type at an exact start time,
  locking the row `FOR UPDATE`.

  Must be called inside a transaction; the row lock serialises concurrent
  seat bookings for the same slot.
  """
  @spec get_live_for_update(integer() | nil, DateTime.t()) :: Meeting.t() | nil
  # A meeting whose type was deleted (`meeting_type_id` nilified) has nothing
  # to join: there is no "same meeting type" left to look a slot up by, so
  # every seat lands on a fresh meeting row instead of an unsafe `== nil`
  # comparison.
  def get_live_for_update(nil, %DateTime{}), do: nil

  def get_live_for_update(meeting_type_id, %DateTime{} = start_time) do
    meeting_type_id
    |> live_at_query(start_time)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc """
  Locks a group meeting row by id `FOR UPDATE`, whatever its status.

  Must be called inside a transaction. Seat cancellation and seat reschedule
  take this lock before counting the remaining participants, so that they
  serialise against `get_live_for_update/2`: a booker joining the slot and the
  last participant leaving it cannot both believe they won.
  """
  @spec lock_for_update(binary()) :: Meeting.t() | nil
  def lock_for_update(meeting_id) when is_binary(meeting_id) do
    Meeting
    |> where([m], m.id == ^meeting_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc """
  Fetches the live group meeting for a meeting type at an exact start time
  without locking.

  Used by read paths (booking-time validation) that only need the meeting's
  identity; the booking transaction itself re-reads the row through
  `get_live_for_update/2`.
  """
  @spec get_live_at(integer() | nil, DateTime.t()) :: Meeting.t() | nil
  def get_live_at(nil, %DateTime{}), do: nil

  def get_live_at(meeting_type_id, %DateTime{} = start_time) do
    meeting_type_id
    |> live_at_query(start_time)
    |> Repo.one()
  end

  @doc """
  Lists live meetings of a meeting type whose start time falls inside the
  given UTC window, ordered by start time.

  Used by the availability seat overlay to find joinable slots.
  """
  @spec list_live_for_type_in_range(integer(), DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def list_live_for_type_in_range(meeting_type_id, %DateTime{} = from_utc, %DateTime{} = to_utc) do
    Meeting
    |> MeetingState.where_slot_live()
    |> where([m], m.meeting_type_id == ^meeting_type_id)
    |> where([m], m.start_time >= ^from_utc and m.start_time <= ^to_utc)
    |> order_by([m], asc: m.start_time)
    |> Repo.all()
  end

  @doc """
  Sets `capacity` on a meeting type's future, live group meetings
  (`capacity > 1`, start time after `now`), returning how many were updated.

  A meeting never ends up with a capacity below the seats already taken on
  it (live participants plus their guests, the count
  `ParticipantQueries.count_seats_taken/1` makes): lowering the limit under
  that leaves the slot exactly full, and nobody is cancelled. Solo meetings
  (`capacity == 1`) are never touched, so a one-to-one booking stays private
  whatever the type becomes.
  """
  @spec set_future_group_capacity(integer(), pos_integer(), DateTime.t()) :: non_neg_integer()
  def set_future_group_capacity(meeting_type_id, capacity, %DateTime{} = now)
      when is_integer(capacity) and capacity > 1 do
    {count, _returning} =
      Meeting
      |> MeetingState.where_slot_live()
      |> where([m], m.meeting_type_id == ^meeting_type_id)
      |> where([m], m.capacity > 1 and m.capacity != ^capacity)
      |> where([m], m.start_time > ^now)
      |> update([m],
        set: [
          capacity:
            fragment(
              """
              GREATEST(?::integer, (
                SELECT count(DISTINCT p.id) + count(g.id)
                FROM meeting_participants AS p
                LEFT JOIN meeting_guests AS g ON g.participant_id = p.id
                WHERE p.meeting_id = ? AND p.cancelled_at IS NULL
              )::integer)
              """,
              ^capacity,
              m.id
            ),
          updated_at: ^DateTime.truncate(now, :second)
        ]
      )
      |> Repo.update_all([])

    count
  end

  @doc "Creates a group meeting (bookers live in meeting_participants, not attendee_* fields)."
  @spec create_group_meeting(map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def create_group_meeting(attrs) when is_map(attrs) do
    %Meeting{}
    |> Meeting.group_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The calendar identities (`calendar_uid`) of the organiser's group meetings
  with live seats that overlap the UTC window `[from_utc, to_utc)`: the ones
  the calendar grid shows locked in the range it has loaded.

  A group meeting has live seats while its slot is live
  (`MeetingState.where_slot_live/1`) and at least one participant has not
  cancelled. Its time then belongs to the bookers, so the organiser's
  provider event must not be moved, deleted or re-attended from the grid.

  Keyed by `calendar_uid` rather than id because the consumer is the
  calendar grid, which knows provider events, and a Tymeslot booking's
  provider event carries the meeting's `calendar_uid` (never its `uid`, the
  booking's bearer capability).
  """
  @spec group_booking_uids_for_user(integer(), DateTime.t(), DateTime.t()) ::
          MapSet.t(String.t())
  def group_booking_uids_for_user(user_id, %DateTime{} = from_utc, %DateTime{} = to_utc)
      when is_integer(user_id) do
    user_id
    |> live_seats_query()
    |> where([meeting: m], m.start_time < ^to_utc and m.end_time > ^from_utc)
    |> where([meeting: m], not is_nil(m.calendar_uid))
    |> select([meeting: m], m.calendar_uid)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Whether the organiser's meeting whose calendar event carries `uid` (its
  `calendar_uid`) is a group meeting with live seats.

  The authoritative form of `group_booking_uids_for_user/3`, for guards that
  must not act on a set assigned when the range was loaded. Another
  organiser's meeting never matches.
  """
  @spec group_booking_uid?(integer(), term()) :: boolean()
  def group_booking_uid?(user_id, uid) when is_integer(user_id) and is_binary(uid) do
    user_id
    |> live_seats_query()
    |> where([meeting: m], m.calendar_uid == ^uid)
    |> Repo.exists?()
  end

  def group_booking_uid?(_user_id, _uid), do: false

  defp live_seats_query(user_id) do
    from(m in Meeting, as: :meeting)
    |> MeetingState.where_slot_live()
    |> where([meeting: m], m.organizer_user_id == ^user_id and m.capacity > 1)
    |> where(
      [meeting: m],
      exists(
        from(p in Participant,
          where: p.meeting_id == parent_as(:meeting).id and is_nil(p.cancelled_at),
          select: 1
        )
      )
    )
  end

  defp live_at_query(meeting_type_id, start_time) do
    Meeting
    |> MeetingState.where_slot_live()
    |> where([m], m.meeting_type_id == ^meeting_type_id and m.start_time == ^start_time)
  end
end
