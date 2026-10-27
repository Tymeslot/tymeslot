defmodule Tymeslot.Meetings.MeetingConflictQueries do
  @moduledoc """
  Database queries for meeting conflict detection.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  @doc """
  Counts the organiser's live meetings overlapping the buffered window,
  leaving out `exclude_uid` (the meeting being moved, when there is one).

  Used inside the conflict-checked create and update transactions, after
  `lock_organizer_schedule/1`: the lock, not this read, is what keeps a
  concurrent booking from slipping into the window between the count and the
  write. Returns `{:ok, :no_conflicts}` or `{:error, count}`.
  """
  @spec count_conflicts(DateTime.t(), DateTime.t(), String.t() | nil, integer()) ::
          {:ok, :no_conflicts} | {:error, pos_integer()}
  def count_conflicts(buffered_start, buffered_end, exclude_uid, organizer_user_id)
      when is_integer(organizer_user_id) do
    base =
      Meeting
      |> MeetingState.where_slot_live()
      |> where(
        [m],
        m.organizer_user_id == ^organizer_user_id and m.start_time < ^buffered_end and
          m.end_time > ^buffered_start
      )

    query = if exclude_uid, do: from(m in base, where: m.uid != ^exclude_uid), else: base

    case Repo.aggregate(query, :count) do
      0 -> {:ok, :no_conflicts}
      n -> {:error, n}
    end
  end

  # Distinguishes the schedule lock from any other advisory locks the
  # application takes. Arbitrary but must stay stable.
  @organizer_schedule_lock_class 715_001

  @doc """
  Serialises writes to one organiser's schedule within the current
  transaction via `pg_advisory_xact_lock/2`.

  Row locks cannot do this: two bookings competing for an empty window have
  no existing row to lock, and bookings counted against a booking limit
  occupy different, non-overlapping windows. Every booking write takes this
  lock before it reads the schedule (the conflict count, the limit counts)
  and before it locks any meeting row, so that a seat transaction holding a
  meeting row never waits on a booking that holds the lock. The lock is
  re-entrant within the transaction and released on commit or rollback.
  Must be called inside a transaction.
  """
  @spec lock_organizer_schedule(integer()) :: :ok
  def lock_organizer_schedule(organizer_user_id) when is_integer(organizer_user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      @organizer_schedule_lock_class,
      organizer_user_id
    ])

    :ok
  end
end
