defmodule Tymeslot.Bookings.RescheduleRequest do
  @moduledoc """
  Handles reschedule request workflow for meetings.

  This module manages the process when an organizer requests to reschedule a meeting:
  1. Validates the meeting is eligible for rescheduling (via Policy) and that
     a request isn't already pending — a duplicate request is rejected
     rather than re-voiding the slot and re-emailing the attendee
  2. Marks the meeting as awaiting a new time (`reschedule_requested_at`) —
     `status` is left untouched, so the underlying lifecycle status (pending,
     awaiting_payment, confirmed) survives the request instead of being
     overwritten and lost
  3. Deletes pending reminder emails and queues the reschedule request email
     atomically, so the attendee is always told once the slot is voided
  4. Schedules deletion of the calendar event — the original time slot is
     void, exactly as if the meeting were cancelled, until the attendee
     books a new time

  This is distinct from `Bookings.Reschedule` which actually performs the reschedule
  with a new time. This module only initiates the request workflow.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo

  @doc """
  Sends a reschedule request email for a meeting.

  This function:
  1. Checks if the meeting is eligible for rescheduling via Policy, and that
     no reschedule request is already pending
  2. Marks the meeting as awaiting a new time (`reschedule_requested_at`)
  3. Deletes pending reminder email jobs and queues a high-priority email
     job to notify the attendee, atomically — either both happen or neither
     does, so the slot is never voided without the attendee being told
  4. Schedules deletion of the calendar event (fire-and-forget)

  ## Parameters
    - meeting: The meeting struct to send reschedule request for

  ## Returns
    - :ok on success
    - {:error, reason} on failure

  ## Examples

      iex> send_reschedule_request(%Meeting{id: 123, status: "confirmed"})
      :ok

      iex> send_reschedule_request(%Meeting{id: 123, status: "cancelled"})
      {:error, :cannot_reschedule_cancelled}

      iex> send_reschedule_request(%Meeting{id: 123, reschedule_requested_at: ~U[...]})
      {:error, :already_requested}
  """
  @spec send_reschedule_request(MeetingSchema.t()) ::
          :ok | {:error, Policy.reschedule_refusal() | :already_requested | :not_found | term()}
  def send_reschedule_request(meeting) do
    with :ok <- check_requestable(meeting) do
      update_and_send_reschedule_request(meeting)
    end
  end

  # =====================================
  # Private Helper Functions
  # =====================================

  defp check_requestable(meeting) do
    with :ok <- check_not_already_requested(meeting),
         :ok <- Policy.can_request_reschedule?(meeting) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Reschedule request blocked by policy",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end

  # A meeting already awaiting a new time must reject a second request
  # outright — re-stamping `reschedule_requested_at` here would re-run the
  # slot-voiding side effects and queue a duplicate attendee email.
  defp check_not_already_requested(meeting) do
    if MeetingState.awaiting_new_time?(meeting) do
      {:error, :already_requested}
    else
      :ok
    end
  end

  # The original slot is void until the attendee books a new time, so the
  # request email tells the attendee the appointment has been cancelled.
  # The meeting update, reminder cancellation, and email-job insert are all
  # Postgres operations, so they run in one transaction: if the email job
  # can't be durably enqueued, the slot update rolls back too, rather than
  # leaving the meeting voided with no email on its way. Calendar event
  # deletion is scheduled last, outside the transaction — it's an external
  # side effect that already never fails the caller (see
  # `Meetings.cancel_calendar_event/1`), and rebooking recreates both the
  # calendar event (via the update-404 path) and reminders (via the
  # meeting_rescheduled event).
  defp update_and_send_reschedule_request(meeting) do
    requested_at = DateTime.truncate(Clock.utc_now(), :second)

    result =
      Repo.transaction(fn ->
        with {:ok, updated_meeting} <- mark_requested(meeting, requested_at),
             :ok <- Events.reschedule_requested(updated_meeting),
             :ok <- schedule_reschedule_email(updated_meeting) do
          updated_meeting
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, updated_meeting} ->
        # The slot is void from this moment, and the booking page computes its
        # offer from the meetings table, so the cached range must go or the
        # freed time stays greyed out until the entry expires.
        Availability.changed(updated_meeting.organizer_user_id)
        Meetings.cancel_calendar_event(updated_meeting)
        :ok

      {:error, {:refused, reason}} ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("Failed to process reschedule request",
          meeting_id: meeting.id,
          error: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end

  # `meeting` was read before this request was made, so its check above can
  # pass for a meeting another request or a cancellation has already moved
  # on. The guarded write settles it: when it finds nothing to change, the
  # meeting is read again and checked again, so the refusal names what
  # actually happened to it.
  defp mark_requested(meeting, requested_at) do
    case MeetingQueries.mark_reschedule_requested(meeting.id, requested_at) do
      {:ok, updated_meeting} -> {:ok, updated_meeting}
      {:error, :not_requestable} -> {:error, {:refused, refusal_for_current(meeting.id)}}
    end
  end

  defp refusal_for_current(meeting_id) do
    with {:ok, current} <- MeetingQueries.get_meeting(meeting_id),
         {:error, reason} <- check_requestable(current) do
      reason
    else
      {:error, :not_found} -> :not_found
      :ok -> :already_requested
    end
  end

  defp schedule_reschedule_email(meeting) do
    EmailScheduler.schedule_reschedule_request(meeting.id, meeting.reschedule_requested_at)
  end
end
