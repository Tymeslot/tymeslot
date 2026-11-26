defmodule Tymeslot.Meetings.SeatHoldConversion do
  @moduledoc """
  Converting a paid seat hold into a participant: the locks, the refusals
  decided before any write, and the seat taken through
  `Tymeslot.Meetings.SeatWrites`. Called through
  `Tymeslot.Meetings.GroupScheduling.convert_hold/2`.
  """

  alias Tymeslot.ContentTranslations.AttendeeTexts
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHoldQueries
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.Meetings.SeatWrites
  alias Tymeslot.Repo

  @doc """
  Converts the seat hold `hold_id` into a participant once its payment has
  completed, booking its booker and their guests as `book_seat/3` would.

  Runs inside the caller's transaction (the payment webhook's, which holds
  the payment row) and takes the locks in the order every writer of a hold
  takes them: the organiser's schedule lock, the hold's meeting row, then
  the hold. The meeting is found by the hold's `meeting_id`, never by the
  slot the hold snapshotted, as a planned session can move without its holds.

    * A hold still held, or released on its expiry or a failure, converts
      while a slot has room for all its seats: its own meeting while that
      still holds its slot, else the live meeting at that meeting's slot,
      else a new one (`:new_slot`).
    * A hold still held on its own meeting reserved its seats before any
      registration close, so it converts there even once a planned
      session's registration has closed. A hold released already reserves
      nothing and respects the close like any other booking. Decided by the
      hold's state, never its `expires_at`: a delayed webhook or a sweeper
      replay can arrive after the expiry for a payment made inside it.
    * A hold already converted, released because its meeting was cancelled,
      or whose meeting its host has since cancelled is refused as
      `:hold_not_convertible`; its payment is always refunded. A meeting
      cancelled because its last participant left is no host's decision:
      the hold converts onto its slot as a hold whose meeting lapsed does.
    * No room for the hold's seats, a closed registration it did not
      reserve against, or no meeting to join on a type that takes no new
      one, is refused as `:slot_full`.

  Refusals are decided under the locks before anything is written and
  come back as `{:refused, reason}`, leaving the caller's transaction
  usable. Every `{:error, reason}` has rolled the caller's transaction back
  (a refusal met only once writing, `:slot_full`, `:already_booked` or
  `:seat_held` among them, or a unique-slot violation, which a confirmed
  meeting of the organiser's at the slot raises and which has aborted it in
  Postgres), so
  the caller must settle the payment in a fresh transaction.

  The hold stops counting against its slot before the seats are taken, so a
  slot it alone fills still takes it. Joining an `:awaiting_payment` meeting
  confirms it and reports `created_meeting?: true`, as for a free seat.

  Options:
    * `:on_booked`: as for `book_seat/3`, run with the booking once the
      participant exists.
    * `:new_slot` (required): `(hold, meeting -> {:ok, (-> meeting_attrs),
      max_participants} | :none)`, asked only when the hold's own meeting no
      longer holds its slot: the capacity of a meeting the conversion would
      create there and a function building its attrs (called only if it is
      created), or `:none` for a type that takes no new meeting (a
      fixed-date type, whose sessions only its host plans).
  """
  @spec convert_hold(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             meeting: Meeting.t(),
             participant: ParticipantSchema.t(),
             created_meeting?: boolean(),
             on_booked_result: term()
           }}
          | {:refused, :slot_full | :hold_not_convertible}
          | {:error, term()}
  def convert_hold(hold_id, opts) when is_binary(hold_id) do
    hooks = %{
      on_booked: Keyword.get(opts, :on_booked, fn _booking -> {:ok, :noop} end),
      new_slot: Keyword.fetch!(opts, :new_slot),
      join_only: false,
      hold: nil,
      registration_reserved?: false,
      exclude_from_conflicts: fn -> nil end
    }

    case Repo.transaction(fn -> convert_locked(hold_id, hooks) end) do
      {:ok, {:refused, _reason} = refused} -> refused
      {:ok, booking} -> {:ok, booking}
      {:error, _reason} = error -> error
    end
  end

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
        convert_into(target, hold, own, hooks)
      end
    else
      _gone -> {:refused, :hold_not_convertible}
    end
  end

  defp convertible(%SeatHoldSchema{status: :converted}, _own),
    do: {:refused, :hold_not_convertible}

  defp convertible(%SeatHoldSchema{released_reason: :meeting_cancelled}, _own),
    do: {:refused, :hold_not_convertible}

  defp convertible(%SeatHoldSchema{} = hold, %Meeting{status: :cancelled} = own) do
    if cancelled_by_host?(own, hold), do: {:refused, :hold_not_convertible}, else: :ok
  end

  defp convertible(%SeatHoldSchema{}, %Meeting{}), do: :ok
  defp convertible(_hold, _own), do: {:refused, :hold_not_convertible}

  # A meeting cancelled because it emptied (`Tymeslot.Bookings.SeatRelease`)
  # has no live participant and had no open hold when it was cancelled, so
  # this hold had lapsed already. A cancellation by its host (or its
  # calendar) leaves its participants on it, and releases its open holds as
  # `:meeting_cancelled`, one of which a meeting without participants must
  # have had, or it would have emptied already; a planned session never
  # empties.
  defp cancelled_by_host?(%Meeting{planned: true}, _hold), do: true
  defp cancelled_by_host?(_own, %SeatHoldSchema{status: :held}), do: true

  defp cancelled_by_host?(%Meeting{id: meeting_id}, _hold),
    do:
      ParticipantQueries.count_live_for_meeting(meeting_id) > 0 or
        SeatHoldQueries.released_for_meeting?(meeting_id, :meeting_cancelled)

  # Decided by the rule `SeatWrites.take_seat/5` applies once the hold has
  # stopped counting, so a slot found joinable here is joined without a
  # rollback.
  defp conversion_target(hold, own, hooks) do
    if slot_live?(own) do
      join_target_for(own, hold)
    else
      case hooks.new_slot.(hold, own) do
        {:ok, build_attrs, max_participants} ->
          # A second meeting row, locked after the hold. Safe: every path
          # that locks two meetings takes the organiser's schedule lock
          # first (held here), and a writer locking a single meeting never
          # waits on a second one while holding it.
          case GroupMeetingQueries.get_live_for_update(own.meeting_type_id, own.start_time) do
            nil -> create_target_for(build_attrs, max_participants, hold)
            %Meeting{} = live -> join_target_for(live, hold)
          end

        :none ->
          {:refused, :slot_full}
      end
    end
  end

  defp join_target_for(meeting, hold) do
    reserved = own_held_seats(meeting, hold)
    seats_left = meeting.capacity - Seats.seats_occupied(meeting.id) + reserved

    if SeatWrites.joinable?(meeting, hold.seats, seats_left) and
         (reserved > 0 or SeatWrites.registration_open?(meeting)),
       do: {:ok, {:join, meeting, reserved > 0}},
       else: {:refused, :slot_full}
  end

  defp create_target_for(build_attrs, max_participants, hold) do
    if max_participants >= 2 and hold.seats <= max_participants,
      do: {:ok, {:create, build_attrs, max_participants}},
      else: {:refused, :slot_full}
  end

  defp own_held_seats(
         %Meeting{id: meeting_id},
         %SeatHoldSchema{status: :held, meeting_id: meeting_id} = hold
       ),
       do: hold.seats

  defp own_held_seats(_meeting, _hold), do: 0

  defp slot_live?(meeting),
    do: meeting.status in MeetingState.occupying() and not MeetingState.slot_void?(meeting)

  defp convert_into(target, hold, own, hooks) do
    :ok = SeatHoldQueries.mark_converted(hold.id)

    {live_meeting, meeting_attrs, max_participants, hooks} =
      case target do
        {:join, meeting, reserved?} ->
          {meeting, booker_texts(own, hold), meeting.capacity,
           %{hooks | registration_reserved?: reserved?}}

        {:create, build_attrs, max_participants} ->
          {nil, build_attrs.(), max_participants, hooks}
      end

    seat_request = %{
      participant: SeatWrites.hold_snapshot(hold),
      guest_emails: Enum.map(hold.guests, & &1["email"]),
      max_participants: max_participants
    }

    booking = SeatWrites.take_seat(live_meeting, meeting_attrs, seat_request, hold.seats, hooks)
    :ok = SeatHoldQueries.link_participant(hold.id, booking.participant.id)
    SeatWrites.run_on_booked(booking, hooks.on_booked)
  end

  # The booker read the slot in their own language on the hold's own
  # meeting, so their locale's copy of its texts comes with them to the
  # meeting they join (`AttendeeTexts.merge/2`); joining the own meeting
  # again adds nothing.
  defp booker_texts(own, hold) do
    own
    |> Map.take(AttendeeTexts.keys())
    |> Map.put(:attendee_texts, Map.take(own.attendee_texts || %{}, [hold.locale]))
  end
end
