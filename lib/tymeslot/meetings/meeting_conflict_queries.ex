defmodule Tymeslot.Meetings.MeetingConflictQueries do
  @moduledoc """
  Database queries for meeting conflict detection.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  @doc """
  Checks whether any active meetings overlap the given time window.

  Optionally excludes a meeting by UID (for update-without-self-conflict).
  """
  @spec time_conflict_exists?(DateTime.t(), DateTime.t(), String.t() | nil) :: boolean()
  def time_conflict_exists?(start_time, end_time, exclude_uid \\ nil) do
    query =
      Meeting
      |> MeetingState.where_slot_live()
      |> where([m], m.start_time < ^end_time and m.end_time > ^start_time)

    query =
      if exclude_uid do
        from(m in query, where: m.uid != ^exclude_uid)
      else
        query
      end

    Repo.exists?(query)
  end

  @doc """
  Counts conflicting meetings with row-level locking (FOR UPDATE NOWAIT).

  Used inside transactions for atomic conflict-checked create/update.
  Returns `{:ok, :no_conflicts}` or `{:error, count}`.
  """
  @spec count_locked_conflicts(DateTime.t(), DateTime.t(), String.t() | nil, integer() | nil) ::
          {:ok, :no_conflicts} | {:error, pos_integer()}
  def count_locked_conflicts(buffered_start, buffered_end, exclude_uid, organizer_user_id) do
    base =
      Meeting
      |> MeetingState.where_slot_live()
      |> where([m], m.start_time < ^buffered_end and m.end_time > ^buffered_start)

    base =
      if organizer_user_id do
        from(m in base, where: m.organizer_user_id == ^organizer_user_id)
      else
        base
      end

    base = if exclude_uid, do: from(m in base, where: m.uid != ^exclude_uid), else: base

    locked = from(m in base, lock: "FOR UPDATE NOWAIT")
    count_query = from(m in subquery(locked), select: count(m.id))

    case Repo.one(count_query) do
      0 -> {:ok, :no_conflicts}
      n when is_integer(n) -> {:error, n}
      nil -> {:ok, :no_conflicts}
    end
  end

  # Distinguishes booking-limit locks from any other advisory locks the
  # application might take. Arbitrary but must stay stable.
  @booking_limits_lock_class 715_001

  @doc """
  Serialises booking-limit checks for one organizer within the current
  transaction via `pg_advisory_xact_lock/2`.

  Row locks cannot guard limit counts: competing bookings occupy different,
  non-overlapping time windows, so `count_locked_conflicts/4` never sees
  them. The advisory lock is released automatically on commit or rollback.
  Must be called inside a transaction.
  """
  @spec acquire_booking_limits_lock(integer()) :: :ok
  def acquire_booking_limits_lock(organizer_user_id) when is_integer(organizer_user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      @booking_limits_lock_class,
      organizer_user_id
    ])

    :ok
  end
end
