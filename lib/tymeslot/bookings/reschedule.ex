defmodule Tymeslot.Bookings.Reschedule do
  @moduledoc """
  Orchestrates the booking rescheduling process.
  Handles meeting time updates, calendar event migration, and notifications.
  """

  require Logger

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{CalendarJobs, Policy, Validation}
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Repo

  @doc """
  Reschedules an existing meeting.

  This includes:
  1. Validating the new time
  2. Cancelling the original calendar event
  3. Updating meeting times with conflict checking
  4. Creating new calendar event
  5. Sending rescheduling notifications

  Returns {:ok, meeting} or {:error, reason}
  """
  @spec execute(String.t(), map(), any()) :: {:ok, map()} | {:error, term()}
  def execute(meeting_uid, new_params, _form_data) when is_binary(meeting_uid) do
    with {:ok, original_meeting} <- MeetingQueries.get_meeting_by_uid(meeting_uid),
         :ok <- validate_can_reschedule(original_meeting),
         {:ok, new_times} <- prepare_new_times(new_params, original_meeting.organizer_user_id),
         {:ok, updated_meeting} <- apply_time_update_and_schedule_job(original_meeting, new_times) do
      {:ok, updated_meeting}
    else
      {:error, :not_found} -> {:error, "Original meeting not found"}
      error -> error
    end
  end

  # Private functions

  defp apply_time_update_and_schedule_job(meeting, %{
         start_time: start_dt,
         end_time: end_dt,
         duration_minutes: _dur
       }) do
    attrs = %{
      start_time: start_dt,
      end_time: end_dt
    }

    case Repo.transaction(fn ->
           with {:ok, updated} <- update_meeting(meeting, attrs),
                {:ok, _} <- schedule_calendar_job(updated) do
             updated
           else
             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, updated} -> {:ok, updated}
      {:error, :failed_to_update_meeting} -> {:error, :failed_to_update_meeting}
      {:error, _} -> {:error, :failed_to_update_meeting}
    end
  end

  defp validate_can_reschedule(meeting) do
    Policy.can_reschedule_meeting?(meeting)
  end

  defp prepare_new_times(params, organizer_user_id) do
    with {:ok, {start_datetime, end_datetime}} <-
           Validation.parse_meeting_times(
             params.date,
             params.time,
             params.duration,
             params.user_timezone
           ),
         :ok <-
           Validation.validate_booking_time(
             start_datetime,
             params.user_timezone,
             Policy.scheduling_config(organizer_user_id)
           ) do
      {:ok,
       %{
         start_time: start_datetime,
         end_time: end_datetime,
         duration_minutes: TimeSlots.parse_duration(params.duration)
       }}
    end
  end

  defp update_meeting(meeting, attrs) do
    case Scheduling.update_meeting_with_conflict_check(meeting, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} -> {:error, :failed_to_update_meeting}
    end
  end

  defp schedule_calendar_job(updated) do
    CalendarJobs.schedule_job(updated, "update")
  end
end
