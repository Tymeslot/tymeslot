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

  Once the move has committed, `Tymeslot.Bookings.SeatRelease.release/1`
  cancels the old meeting if the mover was the last one on it.
  """

  require Logger

  alias Tymeslot.Bookings.BuildParams
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Notifications.Events
  alias UUID

  @typedoc "New-slot parameters, same shape as `Bookings.Reschedule`."
  @type reschedule_params :: %{
          required(:date) => String.t(),
          required(:time) => String.t(),
          required(:duration) => integer() | String.t(),
          required(:user_timezone) => String.t()
        }

  @spec execute(String.t(), reschedule_params()) ::
          {:ok, %{meeting: struct(), participant: struct(), created_meeting?: boolean()}}
          | {:error, term()}
  def execute(management_token, new_params) when is_binary(management_token) do
    with {:ok, participant} <- ParticipantQueries.get_by_token(management_token),
         :ok <- ensure_live(participant),
         {:ok, old_meeting} <- MeetingQueries.get_meeting(participant.meeting_id),
         :ok <- Policy.can_reschedule_meeting?(old_meeting) do
      meeting_type = resolve_meeting_type(old_meeting)

      case Validation.prepare_new_times(new_params, old_meeting.organizer_user_id, meeting_type) do
        {:ok, new_times} -> move_seat(old_meeting, participant, new_times, meeting_type)
        error -> error
      end
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      error -> error
    end
  end

  defp ensure_live(%{cancelled_at: nil}), do: :ok
  defp ensure_live(_participant), do: {:error, :already_cancelled}

  # The meeting type a rescheduled seat is checked and, if it creates a new
  # slot, built against — the same one the offered grid came from. `nil` when
  # the meeting carries no type or the type has since been deleted; every
  # caller here already falls back to the old meeting's own snapshotted
  # values in that case (see `Tymeslot.Meetings.group?/1`).
  defp resolve_meeting_type(%{meeting_type_id: nil}), do: nil

  defp resolve_meeting_type(old_meeting),
    do: MeetingTypes.get_meeting_type(old_meeting.meeting_type_id, old_meeting.organizer_user_id)

  defp move_seat(old_meeting, participant, new_times, meeting_type) do
    max_participants = max_participants_for(old_meeting, meeting_type)

    old_snapshot = %{
      uid: old_meeting.uid,
      ical_sequence: old_meeting.ical_sequence,
      start_time: old_meeting.start_time,
      end_time: old_meeting.end_time
    }

    guest_emails =
      participant.id
      |> GuestQueries.list_for_participant()
      |> Enum.map(& &1.email)

    old_meeting
    |> new_slot_attrs(new_times, participant)
    |> GroupScheduling.book_seat(seat_request(participant, guest_emails, max_participants),
      on_booked: fn _booking -> ParticipantQueries.cancel(participant) end
    )
    |> handle_move(old_meeting, participant, old_snapshot)
  end

  # The live target meeting's own snapshotted capacity governs when the move
  # joins an existing slot (`GroupScheduling.join_meeting/3` reads it
  # directly); this only matters for the branch that creates a brand-new
  # slot, where it seeds that slot's capacity. The current meeting type's
  # `max_participants` is authoritative there — not the old meeting's own
  # capacity, which may predate a host raising or lowering the limit — falling
  # back to it only when the type no longer resolves.
  defp max_participants_for(_old_meeting, %{max_participants: max}) when is_integer(max),
    do: max

  defp max_participants_for(old_meeting, _meeting_type), do: old_meeting.capacity

  defp handle_move({:ok, booked}, old_meeting, _participant, old_snapshot),
    do: after_commit(old_meeting, old_snapshot, booked)

  defp handle_move({:error, reason}, old_meeting, participant, _old_snapshot)
       when reason in [:slot_full, :time_conflict],
       do: log_and_bounce(old_meeting, participant, reason, :slot_taken)

  defp handle_move({:error, %Ecto.Changeset{} = changeset}, old_meeting, participant, _snapshot) do
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

  defp handle_move({:error, reason}, old_meeting, participant, _old_snapshot),
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
      reason: inspect(reason)
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

  defp after_commit(old_meeting, old_snapshot, booked) do
    # Both slots belong to the same meeting type, so one broadcast covers
    # the freed seat and the taken seat alike; the cache holds availability
    # per organiser, and both slots are theirs.
    SeatEffects.broadcast_and_invalidate(old_meeting)

    release_old_meeting(old_meeting)

    SeatEffects.schedule_calendar_job(booked.meeting, booked.created_meeting?)

    # A move never defers its own notification to the video-room worker —
    # unlike a fresh booking's first seat, the mover already gets their
    # reschedule email (with the old event's cancel attachment) right here;
    # holding it back for a room that may take a while would leave them
    # without the one email confirming the old slot is gone. The room is
    # still worth having ready, quietly, for whoever opens the new event.
    if booked.created_meeting?, do: SeatEffects.schedule_new_slot_effects(booked.meeting)

    Events.seat_rescheduled(booked.meeting, booked.participant, old_snapshot)

    {:ok, booked}
  end

  # If the move emptied the old meeting it is cancelled (calendar event
  # deleted, organiser notified of the cancellation in addition to the
  # reschedule notification — deliberate, both facts are true and each email
  # carries its own ICS). Otherwise the old event is refreshed so its
  # attendee list drops the mover.
  defp release_old_meeting(old_meeting) do
    case SeatRelease.release(old_meeting) do
      {:ok, :meeting_cancelled} ->
        :ok

      {:ok, :seats_remain} ->
        CalendarJobs.schedule_job(old_meeting, "update")

      {:error, :release_check_failed} ->
        # The emptiness check failed rather than the status transition, so
        # the old meeting is still confirmed either way (its transaction
        # rolled back) — refresh its calendar event the same as the
        # `:seats_remain` case rather than leaving it stale. `SeatRelease`
        # has already alerted on the check itself failing.
        CalendarJobs.schedule_job(old_meeting, "update")
    end
  end
end
