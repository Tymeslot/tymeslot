defmodule Tymeslot.Meetings.GroupMeetingQueries do
  @moduledoc """
  Database queries for group meetings: meetings that hold seats for multiple
  participants (meeting types with `max_participants > 1`).

  A group slot is always exactly one live meeting row per
  `(meeting_type_id, start_time)`; these queries locate that row for seat
  booking and for the availability seat overlay.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  @doc """
  Fetches the live group meeting for a meeting type at an exact start time,
  locking the row `FOR UPDATE`.

  Must be called inside a transaction; the row lock serialises concurrent
  seat bookings for the same slot.
  """
  @spec get_live_for_update(integer(), DateTime.t()) :: Meeting.t() | nil
  def get_live_for_update(meeting_type_id, %DateTime{} = start_time) do
    meeting_type_id
    |> live_at_query(start_time)
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
  @spec get_live_at(integer(), DateTime.t()) :: Meeting.t() | nil
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

  defp live_at_query(meeting_type_id, start_time) do
    Meeting
    |> MeetingState.where_slot_live()
    |> where([m], m.meeting_type_id == ^meeting_type_id and m.start_time == ^start_time)
  end
end
