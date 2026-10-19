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
  alias Tymeslot.Availability.Schedules
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
  Atomically creates a meeting with conflict checking. The transaction first
  takes the organiser's schedule lock
  (`MeetingConflictQueries.lock_organizer_schedule/1`), so concurrent
  bookings of one organiser are serialised and each sees the meetings the
  others committed before it counts conflicts. A meeting without an
  organiser is refused with `{:error, :organizer_required}`.

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
             | :organizer_required
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
  Atomically creates a group meeting's slot row with conflict checking, under
  the same schedule lock as `create_meeting_with_conflict_check/2`.

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
             | :organizer_required
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
    meeting_type_id = MapKeys.get(attrs, :meeting_type_id)
    exclude_uid = Keyword.get(opts, :exclude_uid)

    cond do
      is_nil(start_time) or is_nil(end_time) ->
        {:error, :invalid_time_range}

      not is_integer(organizer_user_id) ->
        {:error, :organizer_required}

      true ->
        conflict_checked_transaction(
          %{
            start_time: start_time,
            end_time: end_time,
            organizer_user_id: organizer_user_id,
            meeting_type_id: meeting_type_id,
            exclude_uid: exclude_uid
          },
          build_limit_check(organizer_user_id, start_time, meeting_type_id, exclude_uid, opts),
          fn -> persist_fn.(attrs) end,
          &log_conflict(start_time, end_time, &1)
        )
    end
  rescue
    error ->
      handle_database_error(error, __STACKTRACE__, %{
        operation: operation,
        organizer_user_id: MapKeys.get(attrs, :organizer_user_id)
      })
  end

  @doc """
  Atomically updates a meeting with conflict checking, under the same
  organiser schedule lock as `create_meeting_with_conflict_check/2`. Only a
  change of time is checked; a time change on a meeting without an organiser
  is refused with `{:error, :organizer_required}`.

  A time change is written to the meeting row as it stands under its row
  lock, taken after the schedule lock, never to the possibly stale `meeting`
  passed in. Pass `guard:`, a function of that locked row returning `:ok` or
  `{:error, reason}`, to refuse the write when the row has moved on since
  `meeting` was read; a refusal comes back as `{:error, {:refused, reason}}`,
  and a row deleted meanwhile as `{:error, :not_found}`. Pass
  `locked_attrs:`, a function of the same locked row returning a map, for
  changes derived from the row's current values (a counter to advance, say);
  they are merged over `attrs`.

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
             | :organizer_required
             | :not_found
             | :database_error
             | Changeset.t()
             | {:refused, term()}
             | {:validation_error, Changeset.t()}}
  def update_meeting_with_conflict_check(%Meeting{} = meeting, attrs, opts \\ []) do
    # Only check conflicts if time is being changed
    start_time = MapKeys.get(attrs, :start_time)
    end_time = MapKeys.get(attrs, :end_time)

    cond do
      # No time change, just do regular update without conflict checking
      is_nil(start_time) or is_nil(end_time) ->
        MeetingQueries.update_meeting(meeting, attrs)

      not is_integer(meeting.organizer_user_id) ->
        {:error, :organizer_required}

      true ->
        conflict_checked_transaction(
          %{
            start_time: start_time,
            end_time: end_time,
            organizer_user_id: meeting.organizer_user_id,
            meeting_type_id: meeting.meeting_type_id,
            exclude_uid: meeting.uid
          },
          build_limit_check(
            meeting.organizer_user_id,
            start_time,
            meeting.meeting_type_id,
            meeting.uid,
            opts
          ),
          fn -> update_meeting_in_transaction(meeting, attrs, opts) end,
          &log_update_conflict(meeting, start_time, end_time, &1)
        )
    end
  rescue
    error ->
      handle_database_error(error, __STACKTRACE__, %{operation: "update", meeting_id: meeting.id})
  end

  @doc """
  Runs `write_fn` in a conflict-checked transaction for the slot `meeting`
  already has, for bringing back a meeting that stopped holding it (an
  expired booking whose payment completed late). Under the same organiser
  schedule lock as `create_meeting_with_conflict_check/2`, the organiser's
  live meetings overlapping the buffered slot, other than `meeting` itself,
  are counted; `write_fn` runs, still holding the lock, only when there are
  none.

  Booking limits are not counted again: the meeting was admitted under them
  when it was booked.

  `write_fn` returns the transaction's value or calls `Repo.rollback/1`, and
  locks any row it writes itself. Returns `{:ok, value}`,
  `{:error, :time_conflict}` when the slot has been taken, or
  `{:error, reason}`.
  """
  @spec reinstate_with_conflict_check(Meeting.t(), (-> value)) ::
          {:ok, value}
          | {:error, :time_conflict | :organizer_required | :database_error | term()}
        when value: term()
  def reinstate_with_conflict_check(
        %Meeting{organizer_user_id: organizer_user_id} = meeting,
        write_fn
      )
      when is_integer(organizer_user_id) do
    conflict_checked_transaction(
      %{
        start_time: meeting.start_time,
        end_time: meeting.end_time,
        organizer_user_id: organizer_user_id,
        meeting_type_id: meeting.meeting_type_id,
        exclude_uid: meeting.uid
      },
      nil,
      write_fn,
      &log_conflict(meeting.start_time, meeting.end_time, &1, meeting.id)
    )
  rescue
    error ->
      handle_database_error(error, __STACKTRACE__, %{
        operation: "reinstate",
        meeting_id: meeting.id
      })
  end

  def reinstate_with_conflict_check(%Meeting{}, _write_fn), do: {:error, :organizer_required}

  # Private functions

  # The schedule lock comes first, before the limit counts, the conflict
  # count and any row the write locks: see
  # `MeetingConflictQueries.lock_organizer_schedule/1`.
  defp conflict_checked_transaction(slot, limit_check, write_fn, log_conflict_fn) do
    {buffered_start, buffered_end} =
      compute_buffered_window(
        slot.start_time,
        slot.end_time,
        slot.organizer_user_id,
        slot.meeting_type_id
      )

    Repo.transaction(fn ->
      :ok = MeetingConflictQueries.lock_organizer_schedule(slot.organizer_user_id)

      with :ok <- enforce_booking_limits(limit_check),
           {:ok, :no_conflicts} <-
             MeetingConflictQueries.count_conflicts(
               buffered_start,
               buffered_end,
               slot.exclude_uid,
               slot.organizer_user_id
             ) do
        write_fn.()
      else
        {:error, :booking_limit_reached} ->
          Repo.rollback(:booking_limit_reached)

        {:error, conflicting_count} ->
          log_conflict_fn.(conflicting_count)
          Repo.rollback(:time_conflict)
      end
    end)
  end

  # nil means limits are disabled for this call via opts.
  defp build_limit_check(organizer_user_id, start_time, meeting_type_id, exclude_uid, opts) do
    if Keyword.get(opts, :enforce_booking_limits, true) do
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

    # Runs under the organiser's schedule lock, which is what serialises the
    # limit counts of concurrent bookings.
    if BookingLimits.enabled?(limits) do
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
  # right answer for an ad-hoc block.
  defp buffers(organizer_user_id, meeting_type_id) do
    meeting_type = fetch_meeting_type(meeting_type_id, organizer_user_id)

    %{buffer_before_minutes: buffer_before, buffer_after_minutes: buffer_after} =
      Schedules.booking_config(organizer_user_id, meeting_type)

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
      {:error, changeset} -> Repo.rollback(write_error(changeset))
    end
  end

  defp create_group_meeting_in_transaction(attrs) do
    case attrs |> with_held_venue() |> GroupMeetingQueries.create_group_meeting() do
      {:ok, meeting} -> meeting
      {:error, changeset} -> Repo.rollback({:validation_error, changeset})
    end
  end

  defp log_conflict(start_time, end_time, conflicting_count, meeting_id \\ nil) do
    log_attrs = [
      requested_start: start_time,
      requested_end: end_time,
      conflicting_count: conflicting_count
    ]

    log_attrs = if meeting_id, do: [{:meeting_id, meeting_id} | log_attrs], else: log_attrs

    Logger.info("Meeting time conflict detected during booking attempt", log_attrs)
  end

  defp handle_database_error(error, stacktrace, context) do
    :ok = ErrorTracking.report_error(error, stacktrace, context)
    {:error, :database_error}
  end

  # Locks the row only now, under the schedule lock the caller already holds,
  # keeping the lock order every writer uses (schedule, then rows). The write
  # goes to the locked copy: `meeting` may have been read long before (a
  # reschedule holds it across a calendar provider fetch), and whatever
  # committed to the row since, a cancellation say, must be seen by the guard
  # rather than written over.
  defp update_meeting_in_transaction(meeting, attrs, opts) do
    with {:ok, current} <- MeetingQueries.get_meeting_for_update(meeting.id),
         :ok <- run_guard(Keyword.get(opts, :guard), current),
         attrs = Map.merge(attrs, locked_attrs(Keyword.get(opts, :locked_attrs), current)),
         {:ok, updated_meeting} <- MeetingQueries.update_meeting(current, with_held_venue(attrs)) do
      updated_meeting
    else
      {:error, :not_found} -> Repo.rollback(:not_found)
      {:refused, reason} -> Repo.rollback({:refused, reason})
      {:error, %Changeset{} = changeset} -> Repo.rollback(write_error(changeset))
    end
  end

  defp run_guard(nil, _meeting), do: :ok

  defp run_guard(guard, meeting) when is_function(guard, 1) do
    case guard.(meeting) do
      :ok -> :ok
      {:error, reason} -> {:refused, reason}
    end
  end

  defp locked_attrs(nil, _meeting), do: %{}
  defp locked_attrs(fun, meeting) when is_function(fun, 1), do: fun.(meeting)

  # The organiser's unique slot index can still refuse a write the conflict
  # count let through, when the competing row was written without the
  # schedule lock. That is a lost race for the slot, not invalid input, so
  # it is answered as one. The group create path keeps the changeset: its
  # caller retries the race by joining the winner's meeting.
  defp write_error(changeset) do
    if Meeting.unique_slot_violation?(changeset),
      do: :time_conflict,
      else: {:validation_error, changeset}
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
      meeting_id: meeting.id,
      original_start: meeting.start_time,
      original_end: meeting.end_time,
      requested_start: start_time,
      requested_end: end_time,
      conflicting_count: conflicting_count
    )
  end
end
