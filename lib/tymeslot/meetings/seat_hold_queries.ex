defmodule Tymeslot.Meetings.SeatHoldQueries do
  @moduledoc """
  Database queries for the `seat_holds` table.

  Pure data access only. The seat sums count `held` holds whatever their
  `expires_at`: a hold whose Checkout has lapsed keeps its seats until it is
  released, so a payment completing at the last moment still finds them.
  They follow `ParticipantQueries`' seat counts: the sums for given meeting
  ids look at the holds alone, and the range sum counts only meetings whose
  slot is live (`MeetingState.where_slot_live/1`).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.SeatHoldSchema, as: SeatHold
  alias Tymeslot.Repo

  @doc "Inserts a hold through `SeatHoldSchema.create_changeset/2`."
  @spec insert(map()) :: {:ok, SeatHold.t()} | {:error, Changeset.t()}
  def insert(attrs) when is_map(attrs) do
    attrs
    |> SeatHold.create_changeset()
    |> Repo.insert()
  end

  @doc "Fetches a hold by id; `nil` for none, or an id that is no UUID (one from a URL)."
  @spec get(binary()) :: SeatHold.t() | nil
  def get(id) when is_binary(id) do
    case UUID.cast(id) do
      {:ok, uuid} -> Repo.get(SeatHold, uuid)
      :error -> nil
    end
  end

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

  The update locks the hold's row. A caller that also locks the hold's
  meeting must lock the meeting first and release after, keeping the order
  every writer takes: payment row, then the host's schedule lock, then the
  meeting row, then the hold.
  """
  @spec release(binary(), SeatHold.release_reason()) :: SeatHold.t() | nil
  def release(id, reason) when is_binary(id) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    {_count, rows} =
      SeatHold
      |> where([h], h.id == ^id and h.status == :held)
      |> select([h], h)
      |> Repo.update_all(set: [status: :released, released_reason: reason, updated_at: now])

    List.first(rows)
  end

  @doc """
  Releases every hold still `held` on the meeting `meeting_id`, in one
  conditional update, returning the released holds. The lock order is
  `release/2`'s: lock the meeting first.
  """
  @spec release_held_for_meeting(binary(), SeatHold.release_reason()) :: [SeatHold.t()]
  def release_held_for_meeting(meeting_id, reason) when is_binary(meeting_id) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    {_count, rows} =
      SeatHold
      |> where([h], h.meeting_id == ^meeting_id and h.status == :held)
      |> select([h], h)
      |> Repo.update_all(set: [status: :released, released_reason: reason, updated_at: now])

    rows
  end

  @doc """
  Sets the snapshotted `start_time` of every hold still `held` on the
  meeting `meeting_id`, for a meeting moved to `start_time`.
  """
  @spec restamp_held_for_meeting(binary(), DateTime.t()) :: non_neg_integer()
  def restamp_held_for_meeting(meeting_id, %DateTime{} = start_time)
      when is_binary(meeting_id) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    {count, _rows} =
      SeatHold
      |> where([h], h.meeting_id == ^meeting_id and h.status == :held)
      |> Repo.update_all(set: [start_time: start_time, updated_at: now])

    count
  end

  @doc """
  Marks the hold `id` converted, from `held` or `released` (a late payment
  converts a lapsed hold), clearing any release reason. Call with the hold
  locked (`get_for_update/1`) and found not converted yet; a hold already
  converted raises a `MatchError`.
  """
  @spec mark_converted(binary()) :: :ok
  def mark_converted(id) when is_binary(id) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    {1, _rows} =
      SeatHold
      |> where([h], h.id == ^id and h.status != :converted)
      |> Repo.update_all(set: [status: :converted, released_reason: nil, updated_at: now])

    :ok
  end

  @doc "Links the converted hold `id` to the participant it became."
  @spec link_participant(binary(), binary()) :: :ok
  def link_participant(id, participant_id) when is_binary(id) and is_binary(participant_id) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    {1, _rows} =
      SeatHold
      |> where([h], h.id == ^id and h.status == :converted)
      |> Repo.update_all(set: [participant_id: participant_id, updated_at: now])

    :ok
  end

  @doc """
  Up to `limit` holds still `held` whose `expires_at` is before `cutoff`,
  the least recently touched first (`touch/1`), so holds a sweep has
  already looked at go behind those it has not.
  """
  @spec list_overdue(DateTime.t(), pos_integer()) :: [SeatHold.t()]
  def list_overdue(%DateTime{} = cutoff, limit) when is_integer(limit) and limit > 0 do
    held()
    |> where([h], h.expires_at < ^cutoff)
    |> order_by([h], asc: h.updated_at, asc: h.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Bumps `updated_at` on the hold `id` while it is still `held`."
  @spec touch(binary()) :: :ok
  def touch(id) when is_binary(id) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    {_count, _rows} =
      SeatHold
      |> where([h], h.id == ^id and h.status == :held)
      |> Repo.update_all(set: [updated_at: now])

    :ok
  end

  @doc "Seats held on the meeting `meeting_id`."
  @spec seats_held(binary()) :: non_neg_integer()
  def seats_held(meeting_id) when is_binary(meeting_id) do
    held()
    |> where([h], h.meeting_id == ^meeting_id)
    |> select([h], coalesce(sum(h.seats), 0))
    |> Repo.one()
  end

  @doc "Seats held on each of `meeting_ids`; a meeting without holds is absent."
  @spec seats_held_by_meeting([binary()]) :: %{binary() => non_neg_integer()}
  def seats_held_by_meeting([]), do: %{}

  def seats_held_by_meeting(meeting_ids) when is_list(meeting_ids) do
    held()
    |> where([h], h.meeting_id in ^meeting_ids)
    |> group_by([h], h.meeting_id)
    |> select([h], {h.meeting_id, sum(h.seats)})
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

  @doc "Whether any hold on the meeting `meeting_id` was released for `reason`."
  @spec released_for_meeting?(binary(), SeatHold.release_reason()) :: boolean()
  def released_for_meeting?(meeting_id, reason) when is_binary(meeting_id) do
    SeatHold
    |> where([h], h.meeting_id == ^meeting_id)
    |> where([h], h.status == :released and h.released_reason == ^reason)
    |> Repo.exists?()
  end

  @doc """
  Whether `email` holds seats on the meeting through a `held` hold, matched
  case-insensitively as `seat_holds_live_email_index` matches it.
  """
  @spec held_email_taken?(binary(), String.t()) :: boolean()
  def held_email_taken?(meeting_id, email) when is_binary(meeting_id) and is_binary(email) do
    held()
    |> where([h], h.meeting_id == ^meeting_id)
    |> where([h], fragment("lower(?)", h.email) == fragment("lower(?)", ^email))
    |> Repo.exists?()
  end

  @doc """
  Deletes the converted and released holds last updated before `cutoff`,
  returning `{deleted_count, nil}`. A hold's `updated_at` is set when it
  settles, so this counts from settlement.
  """
  @spec delete_settled_before(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_settled_before(%DateTime{} = cutoff) do
    SeatHold
    |> where([h], h.status in [:converted, :released] and h.updated_at < ^cutoff)
    |> Repo.delete_all()
  end

  defp held, do: where(SeatHold, [h], h.status == :held)

  defp held_on_live_meetings do
    Meeting
    |> MeetingState.where_slot_live()
    |> join(:inner, [m], h in SeatHold, on: h.meeting_id == m.id and h.status == :held)
  end
end
