defmodule Tymeslot.Meetings.SeatHoldQueries do
  @moduledoc """
  Database queries for the `seat_holds` table.

  Pure data access only. The seat sums count `held` holds on meetings whose
  slot is live (`MeetingState.where_slot_live/1`), whatever their
  `expires_at`: a hold whose Checkout has lapsed keeps its seats until it is
  released, so a payment completing at the last moment still finds them.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Meetings.SeatHoldSchema, as: SeatHold
  alias Tymeslot.Repo

  @doc "Inserts a hold through `SeatHoldSchema.create_changeset/2`."
  @spec insert(map()) :: {:ok, SeatHold.t()} | {:error, Changeset.t()}
  def insert(attrs) when is_map(attrs) do
    attrs
    |> SeatHold.create_changeset()
    |> Repo.insert()
  end

  @doc "Fetches a hold by id."
  @spec get(binary()) :: SeatHold.t() | nil
  def get(id) when is_binary(id), do: Repo.get(SeatHold, id)

  @doc "Fetches a hold by id, locking the row `FOR UPDATE`. Call inside a transaction."
  @spec get_for_update(binary()) :: SeatHold.t() | nil
  def get_for_update(id) when is_binary(id) do
    SeatHold
    |> where([h], h.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc """
  Releases the hold `id` if it is still `held`, in one conditional update.
  Returns the released hold, or `nil` when it was no longer held.
  """
  @spec release(binary(), SeatHold.release_reason()) :: SeatHold.t() | nil
  def release(id, reason) when is_binary(id) do
    now = DateTime.utc_now(:second)

    {_count, rows} =
      SeatHold
      |> where([h], h.id == ^id and h.status == :held)
      |> select([h], h)
      |> Repo.update_all(set: [status: :released, released_reason: reason, updated_at: now])

    List.first(rows)
  end

  @doc "Seats held on the meeting `meeting_id`."
  @spec seats_held(binary()) :: non_neg_integer()
  def seats_held(meeting_id) when is_binary(meeting_id) do
    held_on_live_meetings()
    |> where([m], m.id == ^meeting_id)
    |> select([_m, h], coalesce(sum(h.seats), 0))
    |> Repo.one()
  end

  @doc "Seats held on each of `meeting_ids`; a meeting without holds is absent."
  @spec seats_held_by_meeting([binary()]) :: %{binary() => non_neg_integer()}
  def seats_held_by_meeting([]), do: %{}

  def seats_held_by_meeting(meeting_ids) when is_list(meeting_ids) do
    held_on_live_meetings()
    |> where([m], m.id in ^meeting_ids)
    |> group_by([m], m.id)
    |> select([m, h], {m.id, sum(h.seats)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Seats held per meeting start time on live meetings of `meeting_type_id`
  starting in `[from_utc, to_utc)`, as
  `ParticipantQueries.seat_counts_for_range/3` counts participants. A slot
  without holds is absent.
  """
  @spec seats_held_for_range(integer(), DateTime.t(), DateTime.t()) ::
          %{DateTime.t() => non_neg_integer()}
  def seats_held_for_range(meeting_type_id, from_utc, to_utc) do
    held_on_live_meetings()
    |> where([m], m.meeting_type_id == ^meeting_type_id)
    |> where([m], m.start_time >= ^from_utc and m.start_time < ^to_utc)
    |> group_by([m], m.start_time)
    |> select([m, h], {m.start_time, sum(h.seats)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "The `held` holds on a meeting, oldest first."
  @spec list_held_for_meeting(binary()) :: [SeatHold.t()]
  def list_held_for_meeting(meeting_id) when is_binary(meeting_id) do
    SeatHold
    |> where([h], h.meeting_id == ^meeting_id and h.status == :held)
    |> order_by([h], asc: h.inserted_at, asc: h.id)
    |> Repo.all()
  end

  @doc """
  Whether `email` already has a seat on the meeting, matched
  case-insensitively as the unique indexes match it: a live participant
  (`meeting_participants_live_email_index`) or a `held` hold
  (`seat_holds_live_email_index`).
  """
  @spec live_email_taken?(binary(), String.t() | nil) :: boolean()
  def live_email_taken?(_meeting_id, nil), do: false

  def live_email_taken?(meeting_id, email) when is_binary(meeting_id) and is_binary(email) do
    email = String.downcase(email)

    participant =
      from(p in Participant,
        where:
          p.meeting_id == ^meeting_id and is_nil(p.cancelled_at) and
            fragment("lower(?)", p.email) == ^email
      )

    hold =
      from(h in SeatHold,
        where:
          h.meeting_id == ^meeting_id and h.status == :held and
            fragment("lower(?)", h.email) == ^email
      )

    Repo.exists?(participant) or Repo.exists?(hold)
  end

  defp held_on_live_meetings do
    Meeting
    |> MeetingState.where_slot_live()
    |> join(:inner, [m], h in SeatHold, on: h.meeting_id == m.id and h.status == :held)
  end
end
