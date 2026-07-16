defmodule Tymeslot.Bookings.RescheduleRequest do
  @moduledoc """
  Handles reschedule request workflow for meetings.

  This module manages the process when an organizer requests to reschedule a meeting:
  1. Validates the meeting is eligible for rescheduling (via Policy)
  2. Updates the meeting status to "reschedule_requested"
  3. Deletes the calendar event and pending reminder emails — the original time
     slot is void, exactly as if the meeting were cancelled, until the attendee
     books a new time
  4. Schedules a reschedule request email to be sent to the attendee

  This is distinct from `Bookings.Reschedule` which actually performs the reschedule
  with a new time. This module only initiates the request workflow.
  """

  require Logger

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema

  @doc """
  Sends a reschedule request email for a meeting.

  This function:
  1. Checks if the meeting is eligible for rescheduling via Policy
  2. Updates the meeting status to "reschedule_requested"
  3. Deletes the calendar event and pending reminder email jobs
  4. Queues a high-priority email job to notify the attendee

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
  """
  @spec send_reschedule_request(MeetingSchema.t()) :: :ok | {:error, String.t() | atom()}
  def send_reschedule_request(meeting) do
    # First check if rescheduling is allowed by policy
    case Policy.can_reschedule_meeting?(meeting) do
      :ok ->
        update_and_send_reschedule_request(meeting)

      {:error, reason} ->
        Logger.warning("Reschedule request blocked by policy",
          meeting_id: meeting.id,
          reason: reason
        )

        {:error, reason}
    end
  end

  # =====================================
  # Private Helper Functions
  # =====================================

  defp update_and_send_reschedule_request(meeting) do
    # Update the meeting status to reschedule_requested
    case MeetingQueries.update_meeting(meeting, %{status: "reschedule_requested"}) do
      {:ok, updated_meeting} ->
        # The original slot is void until the attendee books a new time, so the
        # request email tells the attendee the appointment has been cancelled.
        # Make the system state match: remove the calendar event and drop any
        # reminders still pointing at the old time. Rebooking recreates both —
        # the calendar sync recreates the event on its update-404 path, and
        # reminders are re-scheduled from the meeting_rescheduled event.
        :ok = Meetings.cancel_calendar_event(updated_meeting)
        :ok = EmailScheduler.cancel_reminder_emails(updated_meeting.id)

        schedule_reschedule_email(updated_meeting)

      {:error, reason} ->
        Logger.error("Failed to update meeting status for reschedule request",
          meeting_id: meeting.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp schedule_reschedule_email(meeting) do
    EmailScheduler.schedule_reschedule_request(meeting.id)
  end
end
