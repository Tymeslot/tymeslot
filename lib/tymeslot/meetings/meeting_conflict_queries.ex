defmodule Tymeslot.Meetings.MeetingConflictQueries do
  @moduledoc """
  Database queries for meeting conflict detection.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  @doc """
  The organiser's live meetings overlapping `[from, to)`, leaving out
  `exclude_uid` (the meeting being moved, when there is one).

  Read inside the conflict-checked create and update transactions, after
  `lock_organizer_schedule/1`: the lock, not this read, is what keeps a
  concurrent booking from slipping into the window between the read and the
  write. Whether a meeting found here actually clashes, once buffers are
  weighed, is `Tymeslot.Meetings.Scheduling`'s decision.
  """
  @spec list_live_in_window(integer(), DateTime.t(), DateTime.t(), String.t() | nil) ::
          [Meeting.t()]
  def list_live_in_window(organizer_user_id, from, to, exclude_uid)
      when is_integer(organizer_user_id) do
    base =
      Meeting
      |> MeetingState.where_slot_live()
      |> where(
        [m],
        m.organizer_user_id == ^organizer_user_id and m.start_time < ^to and m.end_time > ^from
      )

    query = if exclude_uid, do: from(m in base, where: m.uid != ^exclude_uid), else: base

    Repo.all(query)
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
