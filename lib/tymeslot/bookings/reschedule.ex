defmodule Tymeslot.Bookings.Reschedule do
  @moduledoc """
  Orchestrates the booking rescheduling process.
  Handles meeting time updates, calendar event migration, and notifications.
  """

  require Logger

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{CalendarJobs, Errors, Policy, Validation}
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @typedoc "Parameters for rescheduling a meeting to a new time slot."
  @type reschedule_params :: %{
          required(:date) => String.t(),
          required(:time) => String.t(),
          required(:duration) => integer() | String.t(),
          required(:user_timezone) => String.t()
        }

  @doc """
  Reschedules an existing meeting.

  This includes:
  1. Validating the new time
  2. Cancelling the original calendar event
  3. Updating meeting times with conflict checking
  4. Creating new calendar event
  5. Sending rescheduling notifications

  The `organizer_user_id` is required. The meeting lookup is scoped to that
  owner, preventing IDOR attacks from the public booking flow.

  Returns `{:ok, meeting}` or `{:error, reason}`, where `reason` is either a
  semantic atom (`Tymeslot.Bookings.Errors.classified_error/0` — currently
  `:meeting_not_found` when the lookup fails, `:slot_taken` when a
  concurrent booking claims the new time first, or `:failed_to_update_meeting`
  when persisting the new time fails for any other reason) or an arbitrary
  policy/validation string from `Tymeslot.Bookings.Policy` or
  `Tymeslot.Bookings.Validation`.
  """
  @spec execute(String.t(), reschedule_params(), any(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, Errors.classified_error() | String.t()}
  def execute(meeting_uid, new_params, _form_data, organizer_user_id)
      when is_binary(meeting_uid) and is_integer(organizer_user_id) do
    with {:ok, original_meeting} <-
           MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id),
         :ok <- validate_can_reschedule(original_meeting),
         {:ok, new_times} <- prepare_new_times(new_params, original_meeting.organizer_user_id),
         {:ok, updated_meeting} <- apply_time_update_and_schedule_job(original_meeting, new_times) do
      sync_provider_video_room(updated_meeting)
      send_reschedule_notifications(updated_meeting, original_meeting)
      {:ok, updated_meeting}
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      error -> error
    end
  end

  # Private functions

  defp apply_time_update_and_schedule_job(meeting, %{
         start_time: start_dt,
         end_time: end_dt,
         duration_minutes: _dur
       }) do
    # Booking a new time settles any pending organizer reschedule request, so
    # the slot becomes live again — clear the timestamp. `status` is left
    # untouched: it tracks the booking lifecycle (pending, awaiting_payment,
    # confirmed, ...), which a reschedule never changes.
    #
    # Reminder sent-tracking is reset too: the reminder(s) already sent were
    # pinned to the old time, so they must not suppress the re-pinned
    # reminder jobs scheduled for the new time.
    attrs = %{
      start_time: start_dt,
      end_time: end_dt,
      reschedule_requested_at: nil,
      reminders_sent: [],
      reminder_email_sent: false
    }

    case Repo.transaction(fn ->
           with {:ok, updated} <- update_meeting(meeting, attrs),
                {:ok, _result} <- schedule_calendar_job(updated) do
             updated
           else
             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, updated} -> {:ok, updated}
      {:error, :slot_taken} -> {:error, :slot_taken}
      {:error, :failed_to_update_meeting} -> {:error, :failed_to_update_meeting}
      {:error, _reason} -> {:error, :failed_to_update_meeting}
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
      {:error, :time_conflict} -> {:error, :slot_taken}
      {:error, _reason} -> {:error, :failed_to_update_meeting}
    end
  end

  defp schedule_calendar_job(updated) do
    CalendarJobs.schedule_job(updated, "update")
  end

  # Enqueues a supervised, retrying video-sync job so the provider-side meeting
  # (e.g. Zoom) is updated to match the new booking time. Routed through Oban —
  # not done inline — so a transient Zoom 5xx/429 retries instead of permanently
  # desyncing. Never blocks the reschedule: the booking is already updated
  # locally and the join URL remains valid. Whether an integration can still
  # reach the room is decided inside the job by `IntegrationResolver`, so a
  # meeting whose integration was disconnected is still synced rather than left
  # advertising the old time.
  defp sync_provider_video_room(%{video_room_id: nil}), do: :ok
  defp sync_provider_video_room(%{organizer_user_id: nil}), do: :ok

  defp sync_provider_video_room(meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "update") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue provider video sync on reschedule",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp send_reschedule_notifications(updated_meeting, original_meeting) do
    case Events.meeting_rescheduled(updated_meeting, original_meeting) do
      {:ok, _result} ->
        Logger.info("Reschedule notifications sent", meeting_id: updated_meeting.id)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send reschedule notifications",
          meeting_id: updated_meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end
end
