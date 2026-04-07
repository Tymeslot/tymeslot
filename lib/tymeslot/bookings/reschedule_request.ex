defmodule Tymeslot.Bookings.RescheduleRequest do
  @moduledoc """
  Handles reschedule request workflow for meetings.

  This module manages the process when an organizer requests to reschedule a meeting:
  1. Validates the meeting is eligible for rescheduling (via Policy)
  2. Updates the meeting status to "reschedule_requested"
  3. Schedules a reschedule request email to be sent to the attendee

  This is distinct from `Bookings.Reschedule` which actually performs the reschedule
  with a new time. This module only initiates the request workflow.
  """

  require Logger

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.EmailWorker

  @doc """
  Sends a reschedule request email for a meeting.

  This function:
  1. Checks if the meeting is eligible for rescheduling via Policy
  2. Updates the meeting status to "reschedule_requested"
  3. Queues a high-priority email job to notify the attendee

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
    job_params = %{
      "action" => "send_reschedule_request",
      "meeting_id" => meeting.id
    }

    case Oban.insert(EmailWorker.new(job_params, queue: :emails, priority: 1)) do
      {:ok, _job} ->
        Logger.info("Reschedule request email job queued",
          meeting_id: meeting.id,
          status: meeting.status
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to queue reschedule request email",
          meeting_id: meeting.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end
end
