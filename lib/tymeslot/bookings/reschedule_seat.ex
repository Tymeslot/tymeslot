defmodule Tymeslot.Bookings.RescheduleSeat do
  @moduledoc """
  Move-my-seat: reschedules a single participant of a group meeting to a new
  slot of the same meeting type, in one transaction.

  The participant is booked as a fresh seat at the new slot via
  `GroupScheduling.book_seat/3`, carrying over their personal data, answers,
  and guest emails; the old seat is cancelled from inside that same
  transaction through the `:on_booked` callback, so the move is atomic
  without nesting a transaction of our own around it. (Nesting it was worse
  than redundant: `Repo.rollback/1` unwinds to the outermost transaction, so
  `book_seat/3` never saw its own rollback and its retry of the first-booker
  race could not run.) A new management token is generated (the token column
  is unique and the cancelled row keeps the old one); the confirmation email
  delivers the new links.

  On `{:error, :slot_full}` (or a lost race, `:time_conflict`) the
  transaction rolls back, the old seat stands, and `{:error, :slot_taken}`
  is returned so the booking UI's existing bounce-back UX fires unchanged.

  The old seat is cancelled under the old meeting's row lock with a fresh
  liveness re-check, the way `Tymeslot.Bookings.CancelSeat` cancels one: of a
  move and a cancellation of the same seat racing each other, exactly one
  succeeds. A move that loses fails with `{:error, :already_cancelled}` and
  takes no seat at the new slot.

  The move is checked like any other booking of the new time: the
  organiser's connected calendar is re-read (ignoring the group meeting the
  seat joins, whose event already holds the time), and a move that creates a
  new slot is subject to the host's conflict check and booking limits inside
  `Scheduling`'s transaction. A move onto an existing slot adds no meeting
  row and so is not limit-checked. The seat keeps the old meeting's
  duration, type and organiser; the booking page it was submitted from must
  belong to that organiser.

  ## A move off the old meeting's last seat

  When the mover is the old meeting's only live seat, the old meeting is
  cancelled inside the move transaction (`SeatRelease.cancel_if_emptied/1`,
  under the row lock the move already holds), and its time is therefore
  not a conflict for the move: a lone participant can shift their seat by
  half an hour within their own hour. Both the calendar re-read and the
  conflict check leave the old meeting out in that case, and only then.
  While other seats remain on it, the old meeting goes ahead at its old time
  and still occupies the host, so a new slot overlapping it is refused like
  any other clash. Cancelling it in the same transaction is what makes
  leaving it out safe: committed separately, a booker could join the old
  meeting between the move and its cancellation, and the host would hold
  two overlapping meetings.
  """

  require Logger

  alias Tymeslot.Bookings.BuildParams
  alias Tymeslot.Bookings.CalendarCheck
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Notifications.Events
  alias UUID

  @typedoc "New-slot parameters, same shape as `Bookings.Reschedule`."
  @type reschedule_params :: %{
          required(:date) => String.t(),
          required(:time) => String.t(),
          required(:duration) => integer() | String.t(),
          required(:user_timezone) => String.t()
        }

  @spec execute(String.t(), reschedule_params(), integer() | nil) ::
          {:ok, %{meeting: struct(), participant: struct(), created_meeting?: boolean()}}
          | {:error, term()}
  def execute(management_token, new_params, organizer_user_id)
      when is_binary(management_token) do
    with {:ok, participant} <- ParticipantQueries.get_by_token(management_token),
         :ok <- ensure_live(participant),
         {:ok, old_meeting} <- MeetingQueries.get_meeting(participant.meeting_id),
         :ok <- ensure_same_organizer(old_meeting, organizer_user_id),
         :ok <- Policy.can_reschedule_meeting?(old_meeting) do
      meeting_type = resolve_meeting_type(old_meeting)
      config = Policy.scheduling_config(old_meeting.organizer_user_id, meeting_type)
      guest_emails = guest_emails(participant)

      with :ok <- ensure_group_type(meeting_type),
           {:ok, new_times} <-
             Validation.prepare_new_times(new_params, old_meeting, meeting_type, config),
           :ok <- ensure_time_changes(old_meeting, new_times),
           :ok <- verify_calendar_free(old_meeting, participant, new_times, config, guest_emails) do
        move_seat(old_meeting, participant, new_times, meeting_type, guest_emails)
      end
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      error -> error
    end
  end

  @doc """
  The meeting a move of the seat behind `management_token` would cancel
  with it: the seat's meeting when the seat is its only live one and the
  meeting is `organizer_user_id`'s, otherwise `nil`.

  The seat-move booking page leaves this meeting out of the host's busy
  times and booking-limit counts, as the submit does (see "A move off the
  old meeting's last seat" above), so it offers exactly the times the move
  can take: a lone participant sees their own hour as free, while a seat
  sharing its meeting with others sees it busy. An unlocked read, for
  display only; the submit decides again under the old meeting's row lock.
  """
  @spec vacated_meeting(String.t() | nil, integer() | nil) :: struct() | nil
  def vacated_meeting(management_token, organizer_user_id)
      when is_binary(management_token) and is_integer(organizer_user_id) do
    with {:ok, %{participant: participant, meeting: meeting}} <-
           Meetings.fetch_live_seat(management_token),
         :ok <- ensure_same_organizer(meeting, organizer_user_id),
         true <- last_live_seat?(meeting, participant) do
      meeting
    else
      _not_vacated -> nil
    end
  end

  def vacated_meeting(_management_token, _organizer_user_id), do: nil

  defp ensure_live(%{cancelled_at: nil}), do: :ok
  defp ensure_live(_participant), do: {:error, :already_cancelled}

  # The seat link only says which seat to move; the page it was submitted
  # from says whose calendar the new time was picked from. A seat moved from
  # another organiser's page (a hand-edited URL) would be checked against
  # that organiser's schedule while landing on this one's, so it is refused
  # as if the seat did not exist there.
  defp ensure_same_organizer(%{organizer_user_id: id}, id) when is_integer(id), do: :ok
  defp ensure_same_organizer(_old_meeting, _organizer_user_id), do: {:error, :meeting_not_found}

  defp guest_emails(participant) do
    participant.id
    |> GuestQueries.list_for_participant()
    |> Enum.map(& &1.email)
  end

  # A type that is no longer a group type (its limit turned back to one)
  # takes no seat moves: its existing group meetings keep their seats but
  # accept nobody new, and a fresh slot would be a one-seat meeting with no
  # attendee. A deleted type (`nil`) takes none either: a slot created by the
  # move would be a group meeting belonging to no type, which no booking page
  # offers and no type update keeps in step.
  defp ensure_group_type(nil), do: {:error, :seat_not_movable}

  defp ensure_group_type(meeting_type) do
    if MeetingTypeSchema.group?(meeting_type), do: :ok, else: {:error, :seat_not_movable}
  end

  # The participant's own slot is offered on the page like any other with a
  # spot free, and picking it moves nothing: their seat would only collide
  # with itself. Said as what it is rather than as a slot already booked.
  defp ensure_time_changes(old_meeting, new_times) do
    if DateTime.compare(old_meeting.start_time, new_times.start_time) == :eq,
      do: {:error, :seat_time_unchanged},
      else: :ok
  end

  # The meeting type a rescheduled seat is checked and, if it creates a new
  # slot, built against: the same one the offered grid came from. `nil` when
  # the meeting carries no type or the type has since been deleted, which
  # `ensure_group_type/1` refuses.
  defp resolve_meeting_type(%{meeting_type_id: nil}), do: nil

  defp resolve_meeting_type(old_meeting),
    do: MeetingTypes.get_meeting_type(old_meeting.meeting_type_id, old_meeting.organizer_user_id)

  # The same re-read of the organiser's connected calendar that a booking
  # (`Create`) and a whole-meeting reschedule (`Reschedule`) make, through the
  # same module, so a time the host has since blocked elsewhere cannot be
  # moved onto. When the move joins a live group slot, that meeting's own
  # event is excluded, exactly as `Create` excludes it for a joining seat.
  # The old meeting's event is excluded only when the mover is its last seat
  # (see the module doc); with other seats on it, it keeps its time whatever
  # this seat does. That read is unlocked: should someone join the old
  # meeting meanwhile, the conflict check inside the seat transaction
  # re-decides under the lock and counts the old meeting after all. Both
  # refusals collapse to `:slot_taken`.
  defp verify_calendar_free(old_meeting, participant, new_times, config, guest_emails) do
    slot = %{
      organizer_user_id: old_meeting.organizer_user_id,
      start_datetime: new_times.start_time,
      end_datetime: new_times.end_time
    }

    join_target =
      GroupScheduling.join_target(
        old_meeting.meeting_type_id,
        new_times.start_time,
        1 + length(guest_emails)
      )

    vacated = if last_live_seat?(old_meeting, participant), do: old_meeting

    case CalendarCheck.enforce(slot, config, exclude: [join_target, vacated]) do
      :ok -> :ok
      {:error, _reason} -> {:error, :slot_taken}
    end
  end

  # The live target meeting's own snapshotted capacity governs when the move
  # joins an existing slot (`GroupScheduling.join_meeting/3` reads it
  # directly); the type's `max_participants` only seeds the capacity of a
  # brand-new slot, where the current limit is authoritative rather than the
  # old meeting's capacity.
  defp move_seat(old_meeting, participant, new_times, meeting_type, guest_emails) do
    %{max_participants: max_participants} = meeting_type

    old_meeting
    |> new_slot_attrs(new_times, participant)
    |> GroupScheduling.book_seat(seat_request(participant, guest_emails, max_participants),
      also_lock: old_meeting.id,
      exclude_from_conflicts: fn ->
        if last_live_seat?(old_meeting, participant), do: old_meeting.uid
      end,
      on_booked: fn _booking -> vacate_old_seat(old_meeting, participant) end
    )
    |> handle_move(old_meeting, participant)
  end

  # Whether the mover is the old meeting's only live seat, so the move
  # cancels the old meeting with it. Asked inside the seat transaction under
  # the old meeting's row lock (`:also_lock`), where nobody can join or leave
  # the old meeting before the move commits, so the old meeting is left out
  # of the conflict check only when `vacate_old_seat/2` does cancel it.
  defp last_live_seat?(old_meeting, participant) do
    ParticipantQueries.count_live_for_meeting(old_meeting.id) == 1 and
      match?({:ok, %{cancelled_at: nil}}, ParticipantQueries.get(participant.id))
  end

  # Runs inside the seat transaction: cancels the old seat, then the old
  # meeting if that seat was its last. The outcome reaches `after_commit/3`
  # as the booking's `:on_booked_result`. A failure to cancel an emptied old
  # meeting rolls the whole move back: its time may already have been
  # treated as free.
  defp vacate_old_seat(old_meeting, participant) do
    with {:ok, _cancelled_seat} <- cancel_old_seat(old_meeting, participant) do
      SeatRelease.cancel_if_emptied(old_meeting)
    end
  end

  # Runs inside the seat transaction, after the new seat is taken. The old
  # meeting's row lock (already held, see `book_seat/3`'s `:also_lock`) is
  # the one `CancelSeat` takes, so the seat's liveness is re-read under it:
  # a cancellation of this seat that committed first makes the move fail and
  # roll the new seat back, rather than both succeeding.
  defp cancel_old_seat(old_meeting, participant) do
    with %{status: status} when status != "cancelled" <-
           GroupMeetingQueries.lock_for_update(old_meeting.id),
         {:ok, %{cancelled_at: nil} = current} <- ParticipantQueries.get(participant.id) do
      ParticipantQueries.cancel(current)
    else
      _gone -> {:error, :already_cancelled}
    end
  end

  defp handle_move({:ok, booked}, old_meeting, participant),
    do: after_commit(old_meeting, participant, booked)

  defp handle_move({:error, reason}, old_meeting, participant)
       when reason in [:slot_full, :time_conflict],
       do: log_and_bounce(old_meeting, participant, reason, :slot_taken)

  defp handle_move({:error, :already_cancelled}, old_meeting, participant) do
    Logger.info("Seat cancelled by a concurrent request before it could move",
      meeting_id: old_meeting.id,
      participant_id: participant.id
    )

    {:error, :already_cancelled}
  end

  defp handle_move({:error, :booking_limit_reached}, _old_meeting, _participant),
    do: {:error, :booking_limit_reached}

  defp handle_move({:error, %Ecto.Changeset{} = changeset}, old_meeting, participant) do
    cond do
      # The first-booker race exhausted book_seat/3's retry: the target slot
      # was created by someone else in the meantime, which is the same story
      # for the mover as a full slot.
      GroupScheduling.lost_first_booker_race?(changeset) ->
        log_and_bounce(old_meeting, participant, changeset, :slot_taken)

      # The mover already holds a live seat at the target slot (most likely a
      # second tab), which trips the same unique index `CreateGroup` maps to
      # `:already_booked` — that has user-facing copy already; the generic
      # "failed to update" does not.
      duplicate_seat?(changeset) ->
        log_and_bounce(old_meeting, participant, changeset, :already_booked)

      true ->
        log_and_bounce(old_meeting, participant, changeset, :failed_to_update_meeting)
    end
  end

  defp handle_move({:error, reason}, old_meeting, participant),
    do: log_and_bounce(old_meeting, participant, reason, :failed_to_update_meeting)

  defp duplicate_seat?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      to_string(opts[:constraint_name] || "") == "meeting_participants_live_email_index"
    end)
  end

  defp log_and_bounce(old_meeting, participant, reason, error) do
    Logger.error("Failed to reschedule seat",
      meeting_id: old_meeting.id,
      participant_id: participant.id,
      reason: LogFormat.reason(reason)
    )

    {:error, error}
  end

  # Builds the meeting-creation attrs `book_seat/3` passes to `Scheduling`
  # when no live group meeting exists at the target slot yet, routed through
  # the same `Policy.build_meeting_attributes/1` builder `CreateGroup` uses
  # rather than a second hand-built map — so a slot created by a seat move
  # carries the same video integration, description, location, locale,
  # attachments and reminder configuration a fresh booking would give it.
  # `old_meeting.title` (already just the type's name — group meetings are
  # never titled after a single booker) replaces the booker-addressed title
  # the builder produces, exactly as `SeatEffects.slot_attrs/2` does for
  # `CreateGroup`.
  defp new_slot_attrs(old_meeting, new_times, participant) do
    %BuildParams{
      meeting_uid: UUID.uuid4(),
      form_data: %{
        "name" => participant.name,
        "email" => participant.email,
        "message" => participant.message
      },
      start_datetime: new_times.start_time,
      end_datetime: new_times.end_time,
      duration_minutes: new_times.duration_minutes,
      user_timezone: participant.timezone,
      organizer_user_id: old_meeting.organizer_user_id,
      meeting_type_id: old_meeting.meeting_type_id,
      attendee_locale: participant.locale,
      custom_field_answers: participant.custom_field_answers
    }
    |> Policy.build_meeting_attributes()
    |> SeatEffects.slot_attrs(old_meeting.title)
  end

  # Matches Section B's seat_request() contract:
  # %{participant: map, guest_emails: [String.t()], max_participants: pos_integer}
  defp seat_request(participant, guest_emails, max_participants) do
    %{
      participant: %{
        name: participant.name,
        email: participant.email,
        phone: participant.phone,
        company: participant.company,
        message: participant.message,
        timezone: participant.timezone,
        locale: participant.locale,
        custom_field_answers: participant.custom_field_answers
      },
      guest_emails: guest_emails,
      max_participants: max_participants
    }
  end

  defp after_commit(old_meeting, old_participant, booked) do
    # Both slots belong to the same meeting type, so one broadcast covers
    # the freed seat and the taken seat alike; the cache holds availability
    # per organiser, and both slots are theirs.
    SeatEffects.broadcast_and_invalidate(old_meeting)

    old_slot_freed? = finish_old_meeting(old_meeting, booked.on_booked_result)

    SeatEffects.schedule_calendar_job(booked.meeting, booked.created_meeting?)

    # A move never defers its own notification to the video-room worker —
    # unlike a fresh booking's first seat, the mover already gets their
    # reschedule email (with the old event's cancel attachment) right here;
    # holding it back for a room that may take a while would leave them
    # without the one email confirming the old slot is gone. The room is
    # still worth having ready, quietly, for whoever opens the new event.
    if booked.created_meeting?, do: SeatEffects.schedule_new_slot_effects(booked.meeting)

    Events.seat_rescheduled(booked.meeting, booked.participant, old_meeting, old_participant,
      old_slot_freed: old_slot_freed?
    )

    {:ok, booked}
  end

  # If the move emptied the old meeting, it was cancelled with the move and
  # its cancellation is finished here (calendar event deleted), returning
  # `true`: the organiser's one email about the move then also says the old
  # slot is empty and free. Otherwise the old event is refreshed so its
  # attendee list drops the mover.
  defp finish_old_meeting(_old_meeting, {:cancelled, cancelled_meeting}) do
    Cancel.finalise_cancellation(cancelled_meeting)
    true
  end

  defp finish_old_meeting(old_meeting, :seats_remain) do
    CalendarJobs.schedule_job(old_meeting, "update")
    false
  end
end
