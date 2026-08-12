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

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatBroadcast
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
         :ok <- Policy.can_reschedule_meeting?(old_meeting),
         {:ok, new_times} <-
           Validation.prepare_new_times(new_params, old_meeting.organizer_user_id) do
      move_seat(old_meeting, participant, new_times)
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      error -> error
    end
  end

  defp ensure_live(%{cancelled_at: nil}), do: :ok
  defp ensure_live(_participant), do: {:error, :already_cancelled}

  defp move_seat(old_meeting, participant, new_times) do
    # Read off the meeting row itself — snapshotted at creation, so this
    # still works after the meeting type is edited or deleted (`meetings.
    # meeting_type_id` is `nilify_all`, which used to leave nothing to read
    # capacity from). See `Tymeslot.Meetings.group?/1`.
    max_participants = old_meeting.capacity

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
    |> slot_attrs(new_times)
    |> GroupScheduling.book_seat(seat_request(participant, guest_emails, max_participants),
      on_booked: fn _booking -> ParticipantQueries.cancel(participant) end
    )
    |> handle_move(old_meeting, participant, old_snapshot)
  end

  defp handle_move({:ok, booked}, old_meeting, _participant, old_snapshot),
    do: after_commit(old_meeting, old_snapshot, booked)

  defp handle_move({:error, reason}, old_meeting, participant, _old_snapshot)
       when reason in [:slot_full, :time_conflict],
       do: log_and_bounce(old_meeting, participant, reason, :slot_taken)

  defp handle_move({:error, %Ecto.Changeset{} = changeset}, old_meeting, participant, _snapshot) do
    # The first-booker race exhausted book_seat/3's retry: the target slot
    # was created by someone else in the meantime, which is the same story
    # for the mover as a full slot.
    if GroupScheduling.lost_first_booker_race?(changeset) do
      log_and_bounce(old_meeting, participant, changeset, :slot_taken)
    else
      log_and_bounce(old_meeting, participant, changeset, :failed_to_update_meeting)
    end
  end

  defp handle_move({:error, reason}, old_meeting, participant, _old_snapshot),
    do: log_and_bounce(old_meeting, participant, reason, :failed_to_update_meeting)

  defp log_and_bounce(old_meeting, participant, reason, error) do
    Logger.error("Failed to reschedule seat",
      meeting_id: old_meeting.id,
      participant_id: participant.id,
      reason: inspect(reason)
    )

    {:error, error}
  end

  # Builds the meeting-creation attrs Section B's book_seat/3 passes to
  # Scheduling when no live group meeting exists at the target slot yet;
  # everything except the times carries over from the old meeting.
  defp slot_attrs(old_meeting, new_times) do
    %{
      uid: UUID.uuid4(),
      title: old_meeting.title,
      start_time: new_times.start_time,
      end_time: new_times.end_time,
      duration: new_times.duration_minutes,
      status: "confirmed",
      organizer_user_id: old_meeting.organizer_user_id,
      organizer_name: old_meeting.organizer_name,
      organizer_email: old_meeting.organizer_email,
      meeting_type_id: old_meeting.meeting_type_id
    }
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
    AvailabilityCache.invalidate_for_user(old_meeting.organizer_user_id)
    SeatBroadcast.broadcast_seat_change(old_meeting.meeting_type_id)

    release_old_meeting(old_meeting)

    CalendarJobs.schedule_job(
      booked.meeting,
      if(booked.created_meeting?, do: "create", else: "update")
    )

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
      {:ok, :meeting_cancelled} -> :ok
      {:ok, :seats_remain} -> CalendarJobs.schedule_job(old_meeting, "update")
    end
  end
end
