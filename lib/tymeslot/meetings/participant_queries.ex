defmodule Tymeslot.Meetings.ParticipantQueries do
  @moduledoc """
  Database queries for the `meeting_participants` table.

  Pure data access only — seat arithmetic and the traffic-light thresholds
  live in `Tymeslot.Meetings.Seats`; booking rules live in the booking flow.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Meetings.GuestSchema, as: Guest
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Repo

  @doc "Inserts a participant for a meeting."
  @spec insert(map()) :: {:ok, Participant.t()} | {:error, Changeset.t()}
  def insert(attrs) when is_map(attrs) do
    %Participant{}
    |> Participant.creation_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches a participant by their management token."
  @spec get_by_token(String.t()) :: {:ok, Participant.t()} | {:error, :not_found}
  def get_by_token(token) when is_binary(token) do
    case Repo.get_by(Participant, management_token: token) do
      nil -> {:error, :not_found}
      participant -> {:ok, participant}
    end
  end

  @doc "Fetches a participant by primary key."
  @spec get(binary()) :: {:ok, Participant.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(Participant, id) do
      nil -> {:error, :not_found}
      participant -> {:ok, participant}
    end
  end

  @doc "Lists the live (not cancelled) participants of a meeting, oldest first."
  @spec list_live_for_meeting(binary()) :: [Participant.t()]
  def list_live_for_meeting(meeting_id) do
    Participant
    |> where([p], p.meeting_id == ^meeting_id and is_nil(p.cancelled_at))
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  @doc """
  Soft-cancels a participant by stamping `cancelled_at` (defaults to now).
  """
  @spec cancel(Participant.t(), DateTime.t()) ::
          {:ok, Participant.t()} | {:error, Changeset.t()}
  def cancel(%Participant{} = participant, cancelled_at \\ DateTime.utc_now(:second)) do
    participant
    |> Participant.cancel_changeset(cancelled_at)
    |> Repo.update()
  end

  @doc """
  Counts the seats taken on a meeting: live participants plus their guests.
  """
  @spec count_seats_taken(binary()) :: non_neg_integer()
  def count_seats_taken(meeting_id) do
    query =
      from(p in Participant,
        left_join: g in Guest,
        on: g.participant_id == p.id,
        where: p.meeting_id == ^meeting_id and is_nil(p.cancelled_at),
        select: count(p.id, :distinct) + count(g.id)
      )

    Repo.one(query)
  end

  @doc """
  Seats taken per meeting start time for confirmed meetings of a meeting
  type whose `start_time` falls in `[from_utc, to_utc)`. One grouped query
  over meetings, participants and guests; meetings without live
  participants do not appear in the result.
  """
  @spec seat_counts_for_range(integer(), DateTime.t(), DateTime.t()) ::
          %{DateTime.t() => non_neg_integer()}
  def seat_counts_for_range(meeting_type_id, from_utc, to_utc) do
    query =
      from(p in Participant,
        join: m in Meeting,
        on: m.id == p.meeting_id,
        left_join: g in Guest,
        on: g.participant_id == p.id,
        where:
          m.meeting_type_id == ^meeting_type_id and
            m.status == "confirmed" and
            m.start_time >= ^from_utc and
            m.start_time < ^to_utc and
            is_nil(p.cancelled_at),
        group_by: m.start_time,
        select: {m.start_time, count(p.id, :distinct) + count(g.id)}
      )

    query
    |> Repo.all()
    |> Map.new()
  end
end
