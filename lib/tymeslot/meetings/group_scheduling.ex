defmodule Tymeslot.Meetings.GroupScheduling do
  @moduledoc """
  Seat booking for group meeting types (`max_participants > 1`).

  One meeting row holds a slot; each booker is a `meeting_participants` row
  and a booker's guests count towards the seats. `book_seat/3` runs one
  transaction per attempt:

    * an existing live meeting for `(meeting_type_id, start_time)` is locked
      `FOR UPDATE`, the seat count is re-checked under the lock, and the
      participant plus guests are inserted, or the transaction rolls back
      with `{:error, :slot_full}`; a planned session
      (`Tymeslot.Meetings.PlannedSessions`) whose registration has closed
      by then is refused the same way, so a booking validated just before
      the close cannot commit after it;
    * with no live meeting, the meeting is created through the standard
      buffered conflict-checked path together with the first participant.

  Every attempt first takes the organiser's schedule lock
  (`MeetingConflictQueries.lock_organizer_schedule/1`), before any meeting
  row, so seat bookings and moves queue behind solo bookings of the same
  organiser rather than deadlocking against them.

  Two racing first bookers queue on that lock, and the second finds the
  first's committed row and joins it. Every writer that can occupy a slot
  must take the lock; that is the invariant this relies on. The partial
  unique index on `(organizer_user_id, start_time)` is a last backstop for a
  writer that breaks it: the loser's insert fails the constraint, the
  transaction rolls back, and one retry runs down the join path against the
  winner's now-visible row.

  Joining adds no meeting row, so only the creating branch is subject to the
  host's booking limits (enforced inside `Scheduling`'s transaction). A
  caller's pre-check may skip the limits for a slot `join_target/3` reports as
  joinable: should the slot turn out full by the time the seat transaction
  runs, it is refused as `:slot_full` rather than replaced, and should it have
  been cancelled, the new row it is replaced by is limit-checked there.

  A booker who must pay for their seats books with the `:hold` option: under
  the same locks and capacity check, the seats become a
  `Tymeslot.Meetings.SeatHoldSchema` row instead of a participant, counted
  by `Tymeslot.Meetings.Seats` but listed, emailed and synced nowhere. A slot
  a hold creates is `:awaiting_payment` until its first real participant (a
  paid hold converting, or a free seat joining) confirms it; a hold joining
  a live meeting leaves its status alone. Confirming such a slot is when it
  comes into being for its callers, so the seat that does it reports
  `created_meeting?: true` and they run the new-slot effects then. Until
  then it is outside the confirmed-slot unique index, so for it the
  schedule lock is the only guard against a second row. One email holds at
  most one seat on a meeting, held or booked: both paths refuse a second,
  as `:already_booked` when the email has a seat and as `:seat_held` when
  it holds seats through a checkout still open.
  """

  alias Ecto.Changeset
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHoldConversion
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.Meetings.SeatWrites
  alias Tymeslot.Repo

  @typedoc "One booker's request for seats at a slot."
  @type seat_request :: %{
          required(:participant) => map(),
          required(:guest_emails) => [String.t()],
          required(:max_participants) => pos_integer()
        }

  @typedoc "A successfully booked seat: a participant, or a hold (`:hold` option)."
  @type booking :: seat_booking() | hold_booking()

  @type seat_booking :: %{
          required(:meeting) => Meeting.t(),
          required(:participant) => ParticipantSchema.t(),
          required(:created_meeting?) => boolean(),
          optional(:on_booked_result) => term()
        }

  @type hold_booking :: %{
          required(:meeting) => Meeting.t(),
          required(:seat_hold) => SeatHoldSchema.t(),
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
    * `:join_only`: when true, the seat only joins a live meeting and never
      creates one: with nobody's slot to join it is refused as `:slot_full`.
      A fixed-date type's sessions are planned by the host
      (`Tymeslot.Meetings.PlannedSessions`), so a booking for one that was
      cancelled in the meantime must not bring it back as an unplanned slot.
    * `:exclude_from_conflicts`: a function `(-> uid | nil)` run inside the
      transaction once the rows are locked, naming a meeting a newly
      created slot's conflict check and booking-limit count leave out. For
      a meeting the same transaction cancels (a seat move vacating its old
      meeting, see `Tymeslot.Bookings.RescheduleSeat`), whose time is free
      the moment this seat commits.
    * `:in_outer_transaction`: when true, the caller runs this inside a
      transaction of its own (a booking series taking a seat in each of its
      sessions, see `Tymeslot.BookingSeries.Create`). The seat then joins
      that transaction, so a first-booker index collision has already
      aborted it and cannot be retried here: it is refused as `:slot_taken`
      instead. A caller that holds the organiser's schedule lock for its
      whole transaction never meets one, as the lock taken here is the one
      it holds (`pg_advisory_xact_lock` is re-entrant). The participant
      attrs may carry `:series_id` and `:series_position` for such a seat.
    * `:hold`: `%{expires_at: DateTime.t()}` to hold the seats for a booker
      who is paying for them, until `expires_at`, rather than book them. The
      booking then carries `:seat_hold` in place of `:participant` (also in
      what `:on_booked` receives), and a slot it creates is
      `:awaiting_payment`. Any other value is refused as `:invalid_hold`.

  A participant (no `:hold`) joining an `:awaiting_payment` meeting confirms
  it and reports `created_meeting?: true`, as if it had created the slot.

  Returns `{:ok, booking}` or `{:error, :slot_full | :slot_taken |
  :time_conflict | :organizer_required | :already_booked | :seat_held |
  :invalid_hold | Ecto.Changeset.t() | term}`; a slot without an organiser
  is refused with `:organizer_required`, an email already seated on the
  meeting with `:already_booked`, and one holding seats on it with
  `:seat_held`.
  """
  @spec book_seat(map(), seat_request(), keyword()) ::
          {:ok, booking()}
          | {:error,
             :slot_full
             | :slot_taken
             | :time_conflict
             | :organizer_required
             | :already_booked
             | :seat_held
             | :invalid_hold
             | Changeset.t()
             | term()}
  def book_seat(meeting_attrs, seat_request, opts \\ []) do
    seats_requested = 1 + length(seat_request.guest_emails)

    hooks = %{
      on_booked: Keyword.get(opts, :on_booked, fn _booking -> {:ok, :noop} end),
      also_lock: Keyword.get(opts, :also_lock),
      join_only: Keyword.get(opts, :join_only, false),
      exclude_from_conflicts: Keyword.get(opts, :exclude_from_conflicts, fn -> nil end),
      in_outer_transaction: Keyword.get(opts, :in_outer_transaction, false),
      hold: Keyword.get(opts, :hold),
      registration_reserved?: false
    }

    cond do
      not valid_hold?(hooks.hold) ->
        {:error, :invalid_hold}

      # The schedule lock is keyed on the organiser, as in `Scheduling`.
      not is_integer(meeting_attrs.organizer_user_id) ->
        {:error, :organizer_required}

      # A limit of one means the type is no longer a group type: it takes no
      # new seats at all, neither on an existing group meeting nor on a fresh
      # slot (which would otherwise be a capacity-1 meeting with no attendee).
      seat_request.max_participants < 2 or seats_requested > seat_request.max_participants ->
        {:error, :slot_full}

      true ->
        retries = if hooks.in_outer_transaction, do: 0, else: 1
        attempt_booking(meeting_attrs, seat_request, seats_requested, hooks, retries)
    end
  end

  defp valid_hold?(nil), do: true
  defp valid_hold?(%{expires_at: %DateTime{}}), do: true
  defp valid_hold?(_hold), do: false

  @doc """
  Converts the seat hold `hold_id` into a participant once its payment has
  completed; see `Tymeslot.Meetings.SeatHoldConversion.convert_hold/2`.
  """
  defdelegate convert_hold(hold_id, opts), to: SeatHoldConversion

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
      %Meeting{} = meeting -> if SeatWrites.joinable?(meeting, seats_requested), do: meeting
      nil -> nil
    end
  end

  @doc """
  What a booking of `seats_requested` seats would meet at each of `starts`
  for `meeting_type_id`, keyed by the start as given:
  `{:join, meeting, seats_left}` for a live group meeting it would join,
  `{:full, meeting, seats_left}` for a live meeting that would refuse it as
  full, and `:none` where it would create a new slot.

  The joinability rule of `join_target/3`, read unlocked for every start in
  two queries (the meetings, then their seat counts), for a caller weighing
  many starts at once such as the sessions of a series.
  """
  @spec sessions_at(integer(), [DateTime.t()], pos_integer()) :: %{
          DateTime.t() => {:join | :full, Meeting.t(), non_neg_integer()} | :none
        }
  def sessions_at(_meeting_type_id, [], _seats_requested), do: %{}

  def sessions_at(meeting_type_id, starts, seats_requested)
      when is_integer(meeting_type_id) and is_integer(seats_requested) do
    meetings =
      GroupMeetingQueries.list_live_for_type_in_range(
        meeting_type_id,
        DateTime.truncate(Enum.min(starts, DateTime), :second),
        Enum.max(starts, DateTime)
      )

    seats_left = meetings |> Enum.filter(&Meeting.group?/1) |> Seats.seats_left_by_meeting()
    by_start = Map.new(meetings, &{DateTime.to_unix(&1.start_time), &1})

    Map.new(starts, fn start ->
      case Map.fetch(by_start, DateTime.to_unix(start)) do
        {:ok, meeting} ->
          {start, session_state(meeting, Map.get(seats_left, meeting.id, 0), seats_requested)}

        :error ->
          {start, :none}
      end
    end)
  end

  defp session_state(meeting, seats_left, seats_requested) do
    if SeatWrites.joinable?(meeting, seats_requested, seats_left),
      do: {:join, meeting, seats_left},
      else: {:full, meeting, seats_left}
  end

  defp attempt_booking(meeting_attrs, seat_request, seats_requested, hooks, retries_left) do
    result =
      Repo.transaction(fn ->
        # Before any meeting row: `Scheduling` takes the same lock when it
        # creates the slot, and a solo booking holding it must never wait on
        # a row this transaction already locked.
        :ok = MeetingConflictQueries.lock_organizer_schedule(meeting_attrs.organizer_user_id)
        lock_in_order(hooks.also_lock, meeting_attrs)

        live_meeting =
          GroupMeetingQueries.get_live_for_update(
            meeting_attrs.meeting_type_id,
            meeting_attrs.start_time
          )

        live_meeting
        |> SeatWrites.take_seat(meeting_attrs, seat_request, seats_requested, hooks)
        |> SeatWrites.run_on_booked(hooks.on_booked)
      end)

    retry = fn ->
      attempt_booking(meeting_attrs, seat_request, seats_requested, hooks, retries_left - 1)
    end

    case result do
      {:ok, booking} ->
        {:ok, booking}

      {:error, {:validation_error, %Changeset{} = changeset}} ->
        cond do
          not Meeting.unique_slot_violation?(changeset) -> {:error, changeset}
          retries_left > 0 -> retry.()
          # The caller's transaction, which the collision has aborted.
          hooks.in_outer_transaction -> {:error, :slot_taken}
          true -> {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
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
end
