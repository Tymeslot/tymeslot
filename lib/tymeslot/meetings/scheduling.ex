defmodule Tymeslot.Meetings.Scheduling do
  @moduledoc """
  Business logic for meeting scheduling, conflict detection, and time management.

  This module handles:
  - Conflict detection with buffered time windows
  - Atomic meeting creation/updates with conflict checking
  - Buffer time calculations based on organizer settings
  """

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Meetings.BookingLimits
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Utils.MapKeys
  alias Tymeslot.Utils.TimeRange
  alias Tymeslot.Venues

  @doc """
  Atomically creates a meeting with conflict checking using database-level locking.
  This function ensures no race conditions can occur by using a database transaction
  with row-level locking to prevent concurrent bookings of overlapping time slots.

  The host's booking limits are enforced in the same transaction. Pass
  `enforce_booking_limits: false` (host-created ad-hoc bookings) to skip
  them; conflict checking always runs.

  ## Examples

      iex> create_meeting_with_conflict_check(%{uid: "unique-123", title: "Meeting", start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:ok, %Meeting{}}

      iex> create_meeting_with_conflict_check(%{uid: "conflicting-123", title: "Meeting", start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:error, :time_conflict}

  """
  @spec create_meeting_with_conflict_check(map(), keyword()) ::
          {:ok, Meeting.t()}
          | {:error,
             :time_conflict
             | :booking_limit_reached
             | :invalid_time_range
             | :database_error
             | {:validation_error, Changeset.t()}}
  def create_meeting_with_conflict_check(attrs, opts \\ []) do
    create_with_conflict_check(
      attrs,
      &create_meeting_in_transaction/1,
      "create",
      opts
    )
  end

  @doc """
  Atomically creates a group meeting's slot row with conflict checking, using
  the same buffered `FOR UPDATE` locking as `create_meeting_with_conflict_check/2`.

  Used for the first booker of a group meeting type, where a fresh meeting
  row is created together with the first seat.

  Takes the options `create_meeting_with_conflict_check/2` does, plus
  `:exclude_uid`: a meeting left out of both the conflict check and the
  booking-limit count, as an update leaves out the meeting it moves. Only
  for a meeting the caller's own transaction is about to cancel (a seat
  move vacating its old meeting); anything else it names would be
  double-booked.
  """
  @spec create_group_meeting_with_conflict_check(map(), keyword()) ::
          {:ok, Meeting.t()}
          | {:error,
             :time_conflict
             | :booking_limit_reached
             | :invalid_time_range
             | :database_error
             | {:validation_error, Changeset.t()}}
  def create_group_meeting_with_conflict_check(attrs, opts \\ []) do
    create_with_conflict_check(
      attrs,
      &create_group_meeting_in_transaction/1,
      "create_group",
      opts
    )
  end

  defp create_with_conflict_check(attrs, persist_fn, operation, opts) do
    start_time = MapKeys.get(attrs, :start_time)
    end_time = MapKeys.get(attrs, :end_time)
    organizer_user_id = MapKeys.get(attrs, :organizer_user_id)

    if start_time && end_time do
      exclude_uid = Keyword.get(opts, :exclude_uid)

      limit_check =
        build_limit_check(
          organizer_user_id,
          start_time,
          MapKeys.get(attrs, :meeting_type_id),
          exclude_uid,
          opts
        )

      execute_conflict_checked_transaction(
        {start_time, end_time},
        organizer_user_id,
        MapKeys.get(attrs, :meeting_type_id),
        exclude_uid,
        limit_check,
        fn ->
          persist_fn.(attrs)
        end
      )
    else
      {:error, :invalid_time_range}
    end
  rescue
    error ->
      handle_database_error(error, __STACKTRACE__, %{
        operation: operation,
        organizer_user_id: MapKeys.get(attrs, :organizer_user_id)
      })
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
  @spec update_meeting_with_conflict_check(Meeting.t(), map(), keyword()) ::
          {:ok, Meeting.t()}
          | {:error,
             :time_conflict
             | :booking_limit_reached
             | :database_error
             | Changeset.t()
             | {:validation_error, Changeset.t()}}
  def update_meeting_with_conflict_check(%Meeting{} = meeting, attrs, opts \\ []) do
    # Only check conflicts if time is being changed
    start_time = MapKeys.get(attrs, :start_time)
    end_time = MapKeys.get(attrs, :end_time)

    if start_time && end_time do
      execute_update_with_conflict_check(meeting, attrs, start_time, end_time, opts)
    else
      # No time change, just do regular update without conflict checking
      MeetingQueries.update_meeting(meeting, attrs)
    end
  rescue
    error ->
      handle_database_error(error, __STACKTRACE__, %{operation: "update", meeting_id: meeting.id})
  end

  # Private functions

  defp execute_conflict_checked_transaction(
         {start_time, end_time},
         organizer_user_id,
         meeting_type_id,
         exclude_uid,
         limit_check,
         operation_fn
       ) do
    {buffered_start, buffered_end} =
      compute_buffered_window(start_time, end_time, organizer_user_id, meeting_type_id)

    Repo.transaction(fn ->
      with :ok <- enforce_booking_limits(limit_check),
           {:ok, :no_conflicts} <-
             MeetingConflictQueries.count_locked_conflicts(
               buffered_start,
               buffered_end,
               exclude_uid,
               organizer_user_id
             ) do
        operation_fn.()
      else
        {:error, :booking_limit_reached} ->
          Repo.rollback(:booking_limit_reached)

        {:error, conflicting_count} ->
          log_conflict(start_time, end_time, conflicting_count)
          Repo.rollback(:time_conflict)
      end
    end)
  end

  # nil means limits are not applicable to this call (disabled via opts, or
  # no organizer to protect).
  defp build_limit_check(organizer_user_id, start_time, meeting_type_id, exclude_uid, opts) do
    if Keyword.get(opts, :enforce_booking_limits, true) and is_integer(organizer_user_id) do
      %{
        organizer_user_id: organizer_user_id,
        start_time: start_time,
        meeting_type_id: meeting_type_id,
        exclude_uid: exclude_uid
      }
    end
  end

  defp enforce_booking_limits(nil), do: :ok

  defp enforce_booking_limits(%{organizer_user_id: organizer_user_id} = limit_check) do
    settings = Profiles.get_profile_settings(organizer_user_id)
    meeting_type = fetch_meeting_type(limit_check.meeting_type_id, organizer_user_id)
    limits = BookingLimits.limits_for(settings, meeting_type)

    if BookingLimits.enabled?(limits) do
      # Row locks cannot serialise limit counts — concurrent bookings occupy
      # different, non-overlapping windows — so serialise per host instead.
      # Hosts without limits never reach this and keep full concurrency.
      MeetingConflictQueries.acquire_booking_limits_lock(organizer_user_id)

      Checker.check_booking_allowed(
        organizer_user_id,
        settings,
        meeting_type,
        limit_check.start_time,
        exclude_uid: limit_check.exclude_uid
      )
    else
      :ok
    end
  end

  defp fetch_meeting_type(nil, _organizer_user_id), do: nil

  defp fetch_meeting_type(meeting_type_id, organizer_user_id),
    do: MeetingTypes.get_meeting_type(meeting_type_id, organizer_user_id)

  # The buffers belong to the schedule the meeting type is booked against, so
  # they are read through the same policy resolution the booking page used. A
  # nil meeting type resolves the organiser's default schedule, which is the
  # right answer for an ad-hoc block; a nil organiser resolves no schedule and
  # gets the policy defaults.
  defp buffers(organizer_user_id, meeting_type_id) do
    meeting_type = organizer_user_id && fetch_meeting_type(meeting_type_id, organizer_user_id)

    %{buffer_before_minutes: buffer_before, buffer_after_minutes: buffer_after} =
      Policy.scheduling_config(organizer_user_id, meeting_type)

    {buffer_before, buffer_after}
  end

  # The new meeting is padded, never the meetings it is checked against: an
  # existing meeting's own buffers are not re-applied.
  defp compute_buffered_window(start_time, end_time, organizer_user_id, meeting_type_id) do
    {buffer_before, buffer_after} = buffers(organizer_user_id, meeting_type_id)
    TimeRange.add_buffer(start_time, end_time, buffer_before, buffer_after)
  end

  defp create_meeting_in_transaction(attrs) do
    case attrs |> with_held_venue() |> MeetingQueries.create_meeting() do
      {:ok, meeting} -> meeting
      {:error, changeset} -> Repo.rollback({:validation_error, changeset})
    end
  end

  defp create_group_meeting_in_transaction(attrs) do
    case attrs |> with_held_venue() |> GroupMeetingQueries.create_group_meeting() do
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

  defp handle_database_error(error, stacktrace, context) do
    :ok = ErrorTracking.report_error(error, stacktrace, context)
    {:error, :database_error}
  end

  defp execute_update_with_conflict_check(meeting, attrs, start_time, end_time, opts) do
    {buffered_start, buffered_end} =
      compute_buffered_window(
        start_time,
        end_time,
        meeting.organizer_user_id,
        meeting.meeting_type_id
      )

    limit_check =
      build_limit_check(
        meeting.organizer_user_id,
        start_time,
        meeting.meeting_type_id,
        meeting.uid,
        opts
      )

    Repo.transaction(fn ->
      with :ok <- enforce_booking_limits(limit_check),
           {:ok, :no_conflicts} <-
             MeetingConflictQueries.count_locked_conflicts(
               buffered_start,
               buffered_end,
               meeting.uid,
               meeting.organizer_user_id
             ) do
        update_meeting_in_transaction(meeting, attrs)
      else
        {:error, :booking_limit_reached} ->
          Repo.rollback(:booking_limit_reached)

        {:error, conflicting_count} ->
          log_update_conflict(meeting, start_time, end_time, conflicting_count)
          Repo.rollback(:time_conflict)
      end
    end)
  end

  defp update_meeting_in_transaction(meeting, attrs) do
    case MeetingQueries.update_meeting(meeting, with_held_venue(attrs)) do
      {:ok, updated_meeting} -> updated_meeting
      {:error, changeset} -> Repo.rollback({:validation_error, changeset})
    end
  end

  # A venue deleted between resolving the booker's choice and this write
  # would otherwise refuse the whole booking on its foreign key. The meeting
  # is written without it instead, keeping the address and the
  # arranged-after-booking flag it was resolved to: exactly where it would
  # be had the venue been deleted a moment after the booking.
  defp with_held_venue(%{venue_id: id} = attrs) when is_integer(id),
    do: %{attrs | venue_id: Venues.hold_for_meeting(id)}

  defp with_held_venue(attrs), do: attrs

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
