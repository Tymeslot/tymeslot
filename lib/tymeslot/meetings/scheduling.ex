defmodule Tymeslot.Meetings.Scheduling do
  @moduledoc """
  Business logic for meeting scheduling, conflict detection, and time management.

  This module handles:
  - Conflict detection with buffered time windows
  - Atomic meeting creation/updates with conflict checking
  - Buffer time calculations based on organizer settings
  """

  require Logger

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema, as: Meeting
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  @doc """
  Atomically creates a meeting with conflict checking using database-level locking.
  This function ensures no race conditions can occur by using a database transaction
  with row-level locking to prevent concurrent bookings of overlapping time slots.

  ## Examples

      iex> create_meeting_with_conflict_check(%{uid: "unique-123", title: "Meeting", start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:ok, %Meeting{}}

      iex> create_meeting_with_conflict_check(%{uid: "conflicting-123", title: "Meeting", start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:error, :time_conflict}

  """
  @spec create_meeting_with_conflict_check(map()) ::
          {:ok, Meeting.t()}
          | {:error,
             :time_conflict
             | :invalid_time_range
             | :database_error
             | {:validation_error, Changeset.t()}}
  def create_meeting_with_conflict_check(attrs) do
    start_time = attrs[:start_time] || attrs["start_time"]
    end_time = attrs[:end_time] || attrs["end_time"]
    organizer_user_id = attrs[:organizer_user_id] || attrs["organizer_user_id"]

    if start_time && end_time do
      execute_conflict_checked_transaction(start_time, end_time, organizer_user_id, fn ->
        create_meeting_in_transaction(attrs)
      end)
    else
      {:error, :invalid_time_range}
    end
  rescue
    error ->
      handle_database_error(error, "atomic meeting creation", __STACKTRACE__)
  end

  @doc """
  Atomically updates a meeting with conflict checking using database-level locking.
  This function ensures no race conditions can occur when rescheduling meetings
  by checking for conflicts with other meetings atomically.

  ## Examples

      iex> update_meeting_with_conflict_check(meeting, %{start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:ok, %Meeting{}}

      iex> update_meeting_with_conflict_check(meeting, %{start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:error, :time_conflict}

  """
  @spec update_meeting_with_conflict_check(Meeting.t(), map()) ::
          {:ok, Meeting.t()}
          | {:error,
             :time_conflict | :database_error | Changeset.t() | {:validation_error, Changeset.t()}}
  def update_meeting_with_conflict_check(%Meeting{} = meeting, attrs) do
    # Only check conflicts if time is being changed
    start_time = attrs[:start_time] || attrs["start_time"]
    end_time = attrs[:end_time] || attrs["end_time"]

    if start_time && end_time do
      execute_update_with_conflict_check(meeting, attrs, start_time, end_time)
    else
      # No time change, just do regular update without conflict checking
      MeetingQueries.update_meeting(meeting, attrs)
    end
  rescue
    error ->
      handle_database_error(
        error,
        "atomic meeting update (meeting_id=#{meeting.id})",
        __STACKTRACE__
      )
  end

  @doc """
  Checks if a meeting time slot conflicts with existing meetings.
  Returns true if there's a conflict, false otherwise.

  ## Examples

      iex> has_time_conflict?(~U[2024-01-01 10:00:00Z], ~U[2024-01-01 11:00:00Z])
      false

      iex> has_time_conflict?(~U[2024-01-01 10:00:00Z], ~U[2024-01-01 11:00:00Z], "existing-uid")
      false

  """
  @spec has_time_conflict?(DateTime.t(), DateTime.t(), String.t() | nil) :: boolean()
  def has_time_conflict?(%DateTime{} = start_time, %DateTime{} = end_time, exclude_uid \\ nil) do
    query =
      from(m in Meeting,
        where:
          m.status in ["confirmed", "pending"] and
            (m.start_time < ^end_time and m.end_time > ^start_time)
      )

    query =
      if exclude_uid do
        from(m in query, where: m.uid != ^exclude_uid)
      else
        query
      end

    Repo.exists?(query)
  end

  # Private functions

  defp execute_conflict_checked_transaction(start_time, end_time, organizer_user_id, operation_fn) do
    {buffered_start, buffered_end} =
      compute_buffered_window(start_time, end_time, organizer_user_id)

    Repo.transaction(fn ->
      case check_time_conflicts(buffered_start, buffered_end, nil, organizer_user_id) do
        {:ok, :no_conflicts} ->
          operation_fn.()

        {:error, conflicting_count} ->
          log_conflict(start_time, end_time, conflicting_count)
          Repo.rollback(:time_conflict)
      end
    end)
  end

  defp check_time_conflicts(buffered_start, buffered_end, exclude_uid, organizer_user_id) do
    base =
      from(m in Meeting,
        where:
          m.status in ["confirmed", "pending"] and
            m.start_time < ^buffered_end and
            m.end_time > ^buffered_start
      )

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

  defp get_buffer_minutes(organizer_user_id) do
    if organizer_user_id do
      settings = Profiles.get_profile_settings(organizer_user_id)
      settings.buffer_minutes
    else
      15
    end
  end

  defp compute_buffered_window(start_time, end_time, organizer_user_id) do
    buffer_minutes = get_buffer_minutes(organizer_user_id)

    {
      DateTime.add(start_time, -buffer_minutes, :minute),
      DateTime.add(end_time, buffer_minutes, :minute)
    }
  end

  defp create_meeting_in_transaction(attrs) do
    case MeetingQueries.create_meeting(attrs) do
      {:ok, meeting} -> meeting
      {:error, changeset} -> Repo.rollback({:validation_error, changeset})
    end
  end

  defp log_conflict(start_time, end_time, conflicting_count, meeting_uid \\ nil) do
    log_attrs = [
      requested_start: start_time,
      requested_end: end_time,
      conflicting_count: conflicting_count
    ]

    log_attrs = if meeting_uid, do: [{:meeting_uid, meeting_uid} | log_attrs], else: log_attrs

    Logger.info("Meeting time conflict detected during booking attempt", log_attrs)
  end

  defp handle_database_error(error, operation, stacktrace) do
    formatted = Exception.format(:error, error, stacktrace)
    Logger.error("Database error during #{operation}\n" <> formatted)
    {:error, :database_error}
  end

  defp execute_update_with_conflict_check(meeting, attrs, start_time, end_time) do
    {buffered_start, buffered_end} =
      compute_buffered_window(start_time, end_time, meeting.organizer_user_id)

    Repo.transaction(fn ->
      case check_time_conflicts(
             buffered_start,
             buffered_end,
             meeting.uid,
             meeting.organizer_user_id
           ) do
        {:ok, :no_conflicts} ->
          update_meeting_in_transaction(meeting, attrs)

        {:error, conflicting_count} ->
          log_update_conflict(meeting, start_time, end_time, conflicting_count)
          Repo.rollback(:time_conflict)
      end
    end)
  end

  defp update_meeting_in_transaction(meeting, attrs) do
    case MeetingQueries.update_meeting(meeting, attrs) do
      {:ok, updated_meeting} -> updated_meeting
      {:error, changeset} -> Repo.rollback({:validation_error, changeset})
    end
  end

  defp log_update_conflict(meeting, start_time, end_time, conflicting_count) do
    Logger.warning("Meeting update blocked due to time conflict",
      meeting_uid: meeting.uid,
      original_start: meeting.start_time,
      original_end: meeting.end_time,
      requested_start: start_time,
      requested_end: end_time,
      conflicting_count: conflicting_count
    )
  end
end
