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
  most one seat on a meeting, held or booked: both paths refuse a second as
  `:already_booked`.
  """

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations.AttendeeTexts
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.SeatHoldQueries
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.Seats
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
  :time_conflict | :organizer_required | :already_booked | :invalid_hold |
  Ecto.Changeset.t() | term}`; a slot without an organiser is refused with
  `:organizer_required`, and an email already seated or holding seats on the
  meeting with `:already_booked`.
  """
  @spec book_seat(map(), seat_request(), keyword()) ::
          {:ok, booking()}
          | {:error,
             :slot_full
             | :slot_taken
             | :time_conflict
             | :organizer_required
             | :already_booked
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
      hold: Keyword.get(opts, :hold)
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
  completed, booking its booker and their guests as `book_seat/3` would.

  Runs inside the caller's transaction (the payment webhook's, which holds
  the payment row) and takes the locks in the order every writer of a hold
  takes them: the organiser's schedule lock, the hold's meeting row, then
  the hold. The meeting is found by the hold's `meeting_id`, never by the
  slot the hold snapshotted, as a planned session can move without its holds.

    * A hold still held, or released on its expiry, a failure or its booker
      abandoning the checkout, converts while a slot has room for all its
      seats: its own meeting while that still holds its slot, else the live
      meeting at that meeting's slot, else a new one (`:new_slot`).
    * A hold already converted, released because its meeting was cancelled,
      or whose meeting has since been cancelled is refused as
      `:hold_not_convertible`; its payment is always refunded.
    * No room for the hold's seats, or no meeting to join on a type that
      takes no new one, is refused as `:slot_full`.

  Both refusals are decided under the locks before anything is written, so
  they leave the caller's transaction usable. Any other error rolls it back;
  a unique-slot violation (a confirmed meeting of the organiser's already at
  the slot) has by then aborted it in Postgres.

  The hold stops counting against its slot before the seats are taken, so a
  slot it alone fills still takes it. Joining an `:awaiting_payment` meeting
  confirms it and reports `created_meeting?: true`, as for a free seat.

  Options:
    * `:on_booked`: as for `book_seat/3`, run with the booking once the
      participant exists.
    * `:new_slot`: `(hold, meeting -> {:ok, (-> meeting_attrs), max_participants} | :none)`,
      asked only when the hold's own meeting no longer holds its slot: the
      capacity of a meeting the conversion would create there and a
      function building its attrs (called only if it is created), or
      `:none` for a type that takes no new meeting (a fixed-date type, whose
      sessions only its host plans). Defaults to `:none`.
  """
  @spec convert_hold(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             meeting: Meeting.t(),
             participant: ParticipantSchema.t(),
             created_meeting?: boolean(),
             on_booked_result: term()
           }}
          | {:error, :slot_full | :hold_not_convertible | term()}
  def convert_hold(hold_id, opts \\ []) when is_binary(hold_id) do
    hooks = %{
      on_booked: Keyword.get(opts, :on_booked, fn _booking -> {:ok, :noop} end),
      new_slot: Keyword.get(opts, :new_slot, fn _hold, _meeting -> :none end),
      join_only: false,
      hold: nil,
      exclude_from_conflicts: fn -> nil end
    }

    case Repo.transaction(fn -> convert_locked(hold_id, hooks) end) do
      {:ok, {:error, _refusal} = refused} -> refused
      {:ok, booking} -> {:ok, booking}
      {:error, _reason} = error -> error
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
    if joinable?(meeting, seats_requested, seats_left),
      do: {:join, meeting, seats_left},
      else: {:full, meeting, seats_left}
  end

  # A solo meeting at the slot (a one-to-one booked before the type became a
  # group type) is never joined: it reads as full, so a private booking stays
  # private.
  defp joinable?(meeting, seats_requested),
    do: joinable?(meeting, seats_requested, Seats.seats_left(meeting, meeting.capacity))

  defp joinable?(meeting, seats_requested, seats_left),
    do: Meeting.group?(meeting) and seats_requested <= seats_left

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
        |> take_seat(meeting_attrs, seat_request, seats_requested, hooks)
        |> run_on_booked(hooks.on_booked)
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

  # Joins `live_meeting`, or creates the slot when there is none, under the
  # locks the caller has taken. Shared by `book_seat/3` and `convert_hold/2`.
  defp take_seat(nil, _meeting_attrs, _seat_request, _seats_requested, %{join_only: true}),
    do: Repo.rollback(:slot_full)

  defp take_seat(nil, meeting_attrs, seat_request, seats_requested, hooks),
    do: create_meeting_with_first_seat(meeting_attrs, seat_request, seats_requested, hooks)

  defp take_seat(%Meeting{} = meeting, meeting_attrs, seat_request, seats_requested, hooks) do
    meeting
    |> join_meeting(seat_request, seats_requested, hooks.hold)
    |> add_attendee_texts(meeting_attrs)
  end

  # A slot is created confirmed, or awaiting payment when a hold creates it
  # (`MeetingSchema.group_changeset/2` honours no other status).
  defp create_meeting_with_first_seat(meeting_attrs, seat_request, seats_requested, hooks) do
    # Snapshotted once, at creation, onto the meeting row itself — see
    # `Tymeslot.Meetings.group?/1`. Not re-read from the meeting type later.
    attrs =
      Map.merge(meeting_attrs, %{
        capacity: seat_request.max_participants,
        status: if(hooks.hold, do: :awaiting_payment, else: :confirmed)
      })

    case Scheduling.create_group_meeting_with_conflict_check(attrs,
           exclude_uid: hooks.exclude_from_conflicts.()
         ) do
      {:ok, meeting} ->
        meeting
        |> insert_seat_or_rollback(seat_request, seats_requested, hooks.hold)
        |> Map.merge(%{meeting: meeting, created_meeting?: true})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Gates on the meeting's own capacity, not the caller's
  # `seat_request.max_participants` (which is only the correct capacity for
  # a meeting not yet created, see `create_meeting_with_first_seat/4`); the
  # type keeps a group meeting's capacity in step with its limit. A planned
  # session's registration close is re-read here, on the locked row, for the
  # same reason the seats are: the caller's pre-check read it unlocked.
  defp join_meeting(meeting, seat_request, seats_requested, hold_opts) do
    if joinable?(meeting, seats_requested) and registration_open?(meeting) do
      seat = insert_seat_or_rollback(meeting, seat_request, seats_requested, hold_opts)

      {meeting, confirmed?} =
        if hold_opts, do: {meeting, false}, else: confirm_if_awaiting_payment(meeting)

      Map.merge(seat, %{meeting: meeting, created_meeting?: confirmed?})
    else
      Repo.rollback(:slot_full)
    end
  end

  # A slot a hold created stays `:awaiting_payment` until its first real
  # participant, a free seat joining it or a paid hold converting. That is
  # when the slot comes into being for the seat's callers: it has no
  # calendar event, reminders or video room yet, so the seat reports
  # `created_meeting?: true` and they schedule them. Call with the meeting
  # row locked. Returns the meeting and whether it was confirmed now.
  defp confirm_if_awaiting_payment(%Meeting{status: :awaiting_payment} = meeting) do
    case GroupMeetingQueries.confirm_awaiting_payment(meeting) do
      {:ok, confirmed} -> {confirmed, true}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp confirm_if_awaiting_payment(%Meeting{} = meeting), do: {meeting, false}

  # The joiner read the slot in their own language: their locale's copy of
  # its texts joins the slot's (`AttendeeTexts.merge/2`), under the lock
  # taken above, so two joiners in different languages cannot overwrite
  # each other's copy.
  defp add_attendee_texts(%{meeting: meeting} = booking, meeting_attrs) do
    case AttendeeTexts.merge(meeting, meeting_attrs) do
      texts when texts == meeting.attendee_texts ->
        booking

      texts ->
        case GroupMeetingQueries.set_attendee_texts(meeting, texts) do
          {:ok, updated} -> %{booking | meeting: updated}
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp registration_open?(%Meeting{planned: true} = session), do: PlannedSessions.open?(session)
  defp registration_open?(%Meeting{}), do: true

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

  # Checked under the meeting's row lock, before either insert: the seat's
  # own unique index sees only its own table, so a held email booking a free
  # seat (or the reverse) would otherwise pass it. The indexes stay the
  # backstop within each table.
  defp insert_seat_or_rollback(meeting, seat_request, seats_requested, hold_opts) do
    if email_taken?(meeting.id, seat_request.participant.email),
      do: Repo.rollback(:already_booked)

    case hold_opts do
      nil ->
        %{participant: insert_participant_or_rollback(meeting, seat_request)}

      %{expires_at: _expires_at} ->
        %{seat_hold: insert_hold_or_rollback(meeting, seat_request, seats_requested, hold_opts)}
    end
  end

  defp email_taken?(_meeting_id, nil), do: false

  defp email_taken?(meeting_id, email),
    do:
      ParticipantQueries.live_email_taken?(meeting_id, email) or
        SeatHoldQueries.held_email_taken?(meeting_id, email)

  @hold_snapshot_fields ~w(name email phone company message timezone locale custom_field_answers)a

  # The hold is read unlocked first only to find the organiser whose
  # schedule lock comes before its meeting's row lock.
  defp convert_locked(hold_id, hooks) do
    with %SeatHoldSchema{} = unlocked <- SeatHoldQueries.get(hold_id),
         {:ok, %Meeting{organizer_user_id: organizer_id}} when is_integer(organizer_id) <-
           MeetingQueries.get_meeting(unlocked.meeting_id) do
      :ok = MeetingConflictQueries.lock_organizer_schedule(organizer_id)
      own = GroupMeetingQueries.lock_for_update(unlocked.meeting_id)
      hold = SeatHoldQueries.get_for_update(hold_id)

      with :ok <- convertible(hold, own),
           {:ok, target} <- conversion_target(hold, own, hooks) do
        convert_into(target, hold, hooks)
      end
    else
      _gone -> {:error, :hold_not_convertible}
    end
  end

  defp convertible(%SeatHoldSchema{status: :converted}, _own), do: {:error, :hold_not_convertible}

  defp convertible(%SeatHoldSchema{released_reason: :meeting_cancelled}, _own),
    do: {:error, :hold_not_convertible}

  defp convertible(%SeatHoldSchema{}, %Meeting{status: :cancelled}),
    do: {:error, :hold_not_convertible}

  defp convertible(%SeatHoldSchema{}, %Meeting{}), do: :ok
  defp convertible(_hold, _own), do: {:error, :hold_not_convertible}

  # Decided by the rule `join_meeting/4` applies once the hold has stopped
  # counting, so a slot found joinable here is joined without a rollback.
  defp conversion_target(hold, own, hooks) do
    if slot_live?(own) do
      join_target_for(own, hold)
    else
      case hooks.new_slot.(hold, own) do
        {:ok, build_attrs, max_participants} ->
          case GroupMeetingQueries.get_live_for_update(own.meeting_type_id, own.start_time) do
            nil -> create_target_for(build_attrs, max_participants, hold)
            %Meeting{} = live -> join_target_for(live, hold)
          end

        :none ->
          {:error, :slot_full}
      end
    end
  end

  defp join_target_for(meeting, hold) do
    seats_left = meeting.capacity - Seats.seats_taken(meeting.id) + own_held_seats(meeting, hold)

    if joinable?(meeting, hold.seats, seats_left) and registration_open?(meeting),
      do: {:ok, {:join, meeting}},
      else: {:error, :slot_full}
  end

  defp create_target_for(build_attrs, max_participants, hold) do
    if max_participants >= 2 and hold.seats <= max_participants,
      do: {:ok, {:create, build_attrs, max_participants}},
      else: {:error, :slot_full}
  end

  defp own_held_seats(
         %Meeting{id: meeting_id},
         %SeatHoldSchema{status: :held, meeting_id: meeting_id} = hold
       ),
       do: hold.seats

  defp own_held_seats(_meeting, _hold), do: 0

  defp slot_live?(meeting),
    do: meeting.status in MeetingState.occupying() and not MeetingState.slot_void?(meeting)

  defp convert_into(target, hold, hooks) do
    :ok = SeatHoldQueries.mark_converted(hold.id)

    {live_meeting, meeting_attrs, max_participants} =
      case target do
        {:join, meeting} -> {meeting, %{}, meeting.capacity}
        {:create, build_attrs, max_participants} -> {nil, build_attrs.(), max_participants}
      end

    seat_request = %{
      participant: hold |> Map.from_struct() |> Map.take(@hold_snapshot_fields),
      guest_emails: Enum.map(hold.guests, & &1["email"]),
      max_participants: max_participants
    }

    booking = take_seat(live_meeting, meeting_attrs, seat_request, hold.seats, hooks)
    :ok = SeatHoldQueries.link_participant(hold.id, booking.participant.id)
    run_on_booked(booking, hooks.on_booked)
  end

  defp insert_hold_or_rollback(meeting, seat_request, seats_requested, %{expires_at: expires_at}) do
    attrs =
      seat_request.participant
      |> Map.take(@hold_snapshot_fields)
      |> Map.merge(%{
        meeting_id: meeting.id,
        meeting_type_id: meeting.meeting_type_id,
        start_time: meeting.start_time,
        seats: seats_requested,
        guests: Enum.map(seat_request.guest_emails, &%{"name" => nil, "email" => &1}),
        expires_at: expires_at
      })

    case SeatHoldQueries.insert(attrs) do
      {:ok, hold} ->
        hold

      {:error, %Changeset{} = changeset} ->
        if SeatHoldSchema.duplicate_hold?(changeset),
          do: Repo.rollback(:already_booked),
          else: Repo.rollback(changeset)
    end
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
end
