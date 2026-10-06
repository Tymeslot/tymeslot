defmodule Tymeslot.Meetings.GroupScheduling do
  @moduledoc """
  Seat booking for group meeting types (`max_participants > 1`).

  One meeting row holds a slot; each booker is a `meeting_participants` row
  and a booker's guests count towards the seats. `book_seat/3` runs one
  transaction per attempt:

    * an existing live meeting for `(meeting_type_id, start_time)` is locked
      `FOR UPDATE`, the seat count is re-checked under the lock, and the
      participant plus guests are inserted, or the transaction rolls back
      with `{:error, :slot_full}`;
    * with no live meeting, the meeting is created through the standard
      buffered `FOR UPDATE NOWAIT` conflict-checked path together with the
      first participant.

  Two racing first bookers are resolved by the partial unique index on
  `(organizer_user_id, start_time) where status = 'confirmed'`: the loser's
  insert fails the constraint, the transaction rolls back, and one retry
  runs down the join path against the winner's now-visible row. Should the
  winner commit after the loser found no live meeting but before the
  loser's conflict check ran, the loser sees the winner's row as a time
  conflict instead; that is the same lost race, and gets the same retry
  once the slot is seen to hold a live meeting.

  Joining adds no meeting row, so only the creating branch is subject to the
  host's booking limits (enforced inside `Scheduling`'s transaction). A
  caller's pre-check may skip the limits for a slot `join_target/3` reports as
  joinable: should the slot turn out full by the time the seat transaction
  runs, it is refused as `:slot_full` rather than replaced, and should it have
  been cancelled, the new row it is replaced by is limit-checked there.
  """

  alias Ecto.Changeset
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.Repo

  @unique_slot_constraint "unique_confirmed_meeting_per_organizer_at_time"

  @typedoc "One booker's request for seats at a slot."
  @type seat_request :: %{
          required(:participant) => map(),
          required(:guest_emails) => [String.t()],
          required(:max_participants) => pos_integer()
        }

  @typedoc "A successfully booked seat."
  @type booking :: %{
          required(:meeting) => Meeting.t(),
          required(:participant) => ParticipantSchema.t(),
          required(:created_meeting?) => boolean(),
          optional(:on_booked_result) => term()
        }

  @doc """
  Books one participant (plus their guests) onto the group slot described by
  `meeting_attrs` (`:meeting_type_id` and `:start_time` identify the slot).

  Options:
    * `:on_booked`: a function `(booking -> {:ok, term} | {:error, term})`
      run inside the transaction after the seat is taken; an error return
      rolls the whole seat back. Used by the booking flow to enqueue every
      job the seat owes atomically with it. The `term` of a success is
      returned as the booking's `:on_booked_result`.
    * `:also_lock`: the id of a further meeting the `:on_booked` callback
      will lock (a seat move's old meeting). It is locked together with the
      target slot's row, in id order, before either is read, so that two
      moves in opposite directions between the same two meetings queue
      behind each other instead of deadlocking.
    * `:exclude_from_conflicts`: a function `(-> uid | nil)` run inside the
      transaction once the rows are locked, naming a meeting a newly
      created slot's conflict check and booking-limit count leave out. For
      a meeting the same transaction cancels (a seat move vacating its old
      meeting, see `Tymeslot.Bookings.RescheduleSeat`), whose time is free
      the moment this seat commits.

  Returns `{:ok, booking}` or `{:error, :slot_full | :time_conflict |
  Ecto.Changeset.t() | term}`.
  """
  @spec book_seat(map(), seat_request(), keyword()) ::
          {:ok, booking()} | {:error, :slot_full | :time_conflict | Changeset.t() | term()}
  def book_seat(meeting_attrs, seat_request, opts \\ []) do
    seats_requested = 1 + length(seat_request.guest_emails)

    hooks = %{
      on_booked: Keyword.get(opts, :on_booked, fn _booking -> {:ok, :noop} end),
      also_lock: Keyword.get(opts, :also_lock),
      exclude_from_conflicts: Keyword.get(opts, :exclude_from_conflicts, fn -> nil end)
    }

    # A limit of one means the type is no longer a group type: it takes no
    # new seats at all, neither on an existing group meeting nor on a fresh
    # slot (which would otherwise be a capacity-1 meeting with no attendee).
    if seat_request.max_participants < 2 or seats_requested > seat_request.max_participants do
      {:error, :slot_full}
    else
      attempt_booking(meeting_attrs, seat_request, seats_requested, hooks, _retries_left = 1)
    end
  end

  @doc """
  The live group meeting at `(meeting_type_id, start_time)` that a booking of
  `seats_requested` seats would join, or `nil` when such a booking would
  create a new slot or be refused as full.

  An unlocked read for pre-checks ahead of `book_seat/3`, deciding
  joinability by the same rule the seat transaction applies under its lock,
  so a pre-check can never call joinable a slot the transaction would not
  join.
  """
  @spec join_target(integer() | nil, DateTime.t(), pos_integer()) :: Meeting.t() | nil
  def join_target(meeting_type_id, %DateTime{} = start_time, seats_requested)
      when is_integer(seats_requested) do
    start_utc = start_time |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

    case GroupMeetingQueries.get_live_at(meeting_type_id, start_utc) do
      %Meeting{} = meeting -> if joinable?(meeting, seats_requested), do: meeting
      nil -> nil
    end
  end

  # A solo meeting at the slot (a one-to-one booked before the type became a
  # group type) is never joined: it reads as full, so a private booking stays
  # private.
  defp joinable?(meeting, seats_requested),
    do: Meeting.group?(meeting) and seats_requested <= Seats.seats_left(meeting, meeting.capacity)

  defp attempt_booking(meeting_attrs, seat_request, seats_requested, hooks, retries_left) do
    result =
      Repo.transaction(fn ->
        lock_in_order(hooks.also_lock, meeting_attrs)

        live_meeting =
          GroupMeetingQueries.get_live_for_update(
            meeting_attrs.meeting_type_id,
            meeting_attrs.start_time
          )

        booking =
          case live_meeting do
            nil ->
              create_meeting_with_first_seat(
                meeting_attrs,
                seat_request,
                hooks.exclude_from_conflicts.()
              )

            %Meeting{} = meeting ->
              join_meeting(meeting, seat_request, seats_requested)
          end

        run_on_booked(booking, hooks.on_booked)
      end)

    retry = fn ->
      attempt_booking(meeting_attrs, seat_request, seats_requested, hooks, retries_left - 1)
    end

    case result do
      {:ok, booking} ->
        {:ok, booking}

      {:error, {:validation_error, %Changeset{} = changeset}} ->
        if lost_first_booker_race?(changeset) and retries_left > 0,
          do: retry.(),
          else: {:error, changeset}

      {:error, :time_conflict} ->
        if retries_left > 0 and slot_went_live?(meeting_attrs),
          do: retry.(),
          else: {:error, :time_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The other side of the first-booker race: a concurrent first booker
  # committed the slot's meeting after this attempt found none but before
  # its conflict check, which then counted that meeting as a clash. A live
  # meeting at the exact slot is the meeting this booker would have joined,
  # so the retry joins it (or finds it full). A genuine conflict, with a
  # meeting at any other time, leaves no live meeting at the slot and is
  # returned as it is; the retry budget bounds the rest. The read is
  # unlocked, and only decides whether to retry: the retry re-reads the
  # slot under its lock.
  defp slot_went_live?(meeting_attrs) do
    not is_nil(
      GroupMeetingQueries.get_live_at(meeting_attrs.meeting_type_id, meeting_attrs.start_time)
    )
  end

  defp create_meeting_with_first_seat(meeting_attrs, seat_request, exclude_uid) do
    # Snapshotted once, at creation, onto the meeting row itself — see
    # `Tymeslot.Meetings.group?/1`. Not re-read from the meeting type later.
    attrs = Map.put(meeting_attrs, :capacity, seat_request.max_participants)

    case Scheduling.create_group_meeting_with_conflict_check(attrs, exclude_uid: exclude_uid) do
      {:ok, meeting} ->
        participant = insert_participant_or_rollback(meeting, seat_request)
        %{meeting: meeting, participant: participant, created_meeting?: true}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Gates on the meeting's own capacity, not the caller's
  # `seat_request.max_participants` (which is only the correct capacity for
  # a meeting not yet created, see `create_meeting_with_first_seat/2`); the
  # type keeps a group meeting's capacity in step with its limit.
  defp join_meeting(meeting, seat_request, seats_requested) do
    if joinable?(meeting, seats_requested) do
      participant = insert_participant_or_rollback(meeting, seat_request)
      %{meeting: meeting, participant: participant, created_meeting?: false}
    else
      Repo.rollback(:slot_full)
    end
  end

  # Without a second meeting to lock there is nothing to order: the target
  # row is locked by `get_live_for_update/2` as always. With one, both rows
  # are locked lowest id first; the target's id comes from an unlocked read,
  # and `get_live_for_update/2` re-reads the row under its lock straight
  # after, so a target that changed in between is still locked before use.
  defp lock_in_order(nil, _meeting_attrs), do: :ok

  defp lock_in_order(other_meeting_id, meeting_attrs) do
    target =
      GroupMeetingQueries.get_live_at(meeting_attrs.meeting_type_id, meeting_attrs.start_time)

    [other_meeting_id, target && target.id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&GroupMeetingQueries.lock_for_update/1)
  end

  defp insert_participant_or_rollback(meeting, seat_request) do
    attrs = Map.put(seat_request.participant, :meeting_id, meeting.id)

    with {:ok, participant} <- ParticipantQueries.insert(attrs),
         {:ok, _guests} <-
           Guests.create_for_participant(meeting.id, participant.id, seat_request.guest_emails) do
      participant
    else
      {:error, %Changeset{} = changeset} -> Repo.rollback(changeset)
    end
  end

  defp run_on_booked(booking, on_booked) do
    case on_booked.(booking) do
      {:ok, result} -> Map.put(booking, :on_booked_result, result)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  True when a changeset's error is the loser's side of the first-booker race
  on `(organizer_user_id, start_time)` — the partial unique index this module
  relies on to serialise two concurrent first bookings of the same slot.

  Exposed so callers outside this module (the booking flow's error
  classification) can recognise the same race without duplicating the
  constraint name.
  """
  @spec lost_first_booker_race?(Changeset.t()) :: boolean()
  def lost_first_booker_race?(%Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, error_opts}} ->
      error_opts[:constraint] == :unique and
        to_string(error_opts[:constraint_name] || "") == @unique_slot_constraint
    end)
  end
end
