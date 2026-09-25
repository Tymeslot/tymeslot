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
  Lists the future, live meetings of a meeting type that still carry a solo
  attendee on the meeting row.

  These are the bookings taken before the type became a group type; they are
  what `Tymeslot.Meetings.GroupConversion` gives participant rows to.
  """
  @spec list_convertible_solo_bookings(integer(), DateTime.t()) :: [Meeting.t()]
  def list_convertible_solo_bookings(meeting_type_id, %DateTime{} = from_utc) do
    Meeting
    |> MeetingState.where_slot_live()
    |> where([m], m.meeting_type_id == ^meeting_type_id)
    |> where([m], m.start_time >= ^from_utc)
    |> where([m], not is_nil(m.attendee_email) and m.attendee_email != "")
    |> Repo.all()
  end

  @doc "Creates a group meeting (bookers live in meeting_participants, not attendee_* fields)."
  @spec create_group_meeting(map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def create_group_meeting(attrs) when is_map(attrs) do
    %Meeting{}
    |> Meeting.group_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The `uid`s of the organiser's meetings that are group bookings
  (`capacity > 1`).

  Keyed by `uid` rather than id because the consumer is the calendar grid,
  which knows provider events, and a Tymeslot booking's provider event
  carries the meeting's `uid`.
  """
  @spec group_booking_uids_for_user(integer()) :: MapSet.t(String.t())
  def group_booking_uids_for_user(user_id) do
    Meeting
    |> where([m], m.organizer_user_id == ^user_id and m.capacity > 1)
    |> select([m], m.uid)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Whether the meeting behind `uid` is a group booking (`capacity > 1`).

  The authoritative form of `group_booking_uids_for_user/1`, for guards that
  must not act on a set assigned when the page was loaded.
  """
  @spec group_booking_uid?(term()) :: boolean()
  def group_booking_uid?(uid) when is_binary(uid) do
    Meeting
    |> where([m], m.uid == ^uid and m.capacity > 1)
    |> Repo.exists?()
  end

  def group_booking_uid?(_uid), do: false

  defp live_at_query(meeting_type_id, start_time) do
    Meeting
    |> MeetingState.where_slot_live()
    |> where([m], m.meeting_type_id == ^meeting_type_id and m.start_time == ^start_time)
  end
end
