defmodule Tymeslot.Bookings.RescheduleSeat do
  @moduledoc """
  Move-my-seat: reschedules a single participant of a group meeting to a new
  slot of the same meeting type, in one transaction.

  The participant is cancelled on the old meeting and booked as a fresh seat
  at the new slot via `GroupScheduling.book_seat/2`, carrying over their
  personal data, answers, and guest emails. A new management token is
  generated (the token column is unique and the cancelled row keeps the old
  one); the confirmation email delivers the new links.

  On `{:error, :slot_full}` (or a lost race, `:time_conflict`) the
  transaction rolls back, the old seat stands, and `{:error, :slot_taken}`
  is returned so the booking UI's existing bounce-back UX fires unchanged.
  """

  require Logger

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
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

    %{meeting_type_ref: %{max_participants: max_participants}} =
      Repo.preload(old_meeting, :meeting_type_ref)

    transaction_result =
      Repo.transaction(fn ->
        with {:ok, _cancelled} <- ParticipantQueries.cancel(participant),
             {:ok, booked} <-
               GroupScheduling.book_seat(
                 slot_attrs(old_meeting, new_times),
                 seat_request(participant, guest_emails, max_participants)
               ) do
          {booked, ParticipantQueries.list_live_for_meeting(old_meeting.id)}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, {booked, old_remaining}} ->
        after_commit(old_meeting, old_snapshot, booked, old_remaining)

      {:error, :slot_full} ->
        {:error, :slot_taken}

      {:error, :time_conflict} ->
        {:error, :slot_taken}

      {:error, reason} ->
        Logger.error("Failed to reschedule seat",
          meeting_id: old_meeting.id,
          participant_id: participant.id,
          reason: inspect(reason)
        )

        {:error, :failed_to_update_meeting}
    end
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

  defp after_commit(old_meeting, old_snapshot, booked, old_remaining) do
    # Both slots belong to the same meeting type, so one broadcast covers
    # the freed seat and the taken seat alike.
    SeatBroadcast.broadcast_seat_change(old_meeting.meeting_type_id)

    handle_old_meeting(old_meeting, old_remaining)

    CalendarJobs.schedule_job(
      booked.meeting,
      if(booked.created_meeting?, do: "create", else: "update")
    )

    Events.seat_rescheduled(booked.meeting, booked.participant, old_snapshot)

    {:ok, booked}
  end

  # The move emptied the old meeting: cancel it through the meeting-level
  # flow (calendar event deleted, organiser notified of the cancellation in
  # addition to the reschedule notification — deliberate, both facts are
  # true and each email carries its own ICS).
  defp handle_old_meeting(old_meeting, []) do
    case Cancel.execute(old_meeting) do
      {:ok, _cancelled} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to cancel emptied group meeting after seat reschedule",
          meeting_id: old_meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp handle_old_meeting(old_meeting, _remaining) do
    CalendarJobs.schedule_job(old_meeting, "update")
    :ok
  end
end
