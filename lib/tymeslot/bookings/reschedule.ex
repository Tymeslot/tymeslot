defmodule Tymeslot.Bookings.Reschedule do
  @moduledoc """
  Orchestrates the booking rescheduling process.
  Handles meeting time updates, calendar event migration, and notifications.

  ## Rescheduling does not bypass the approval gate

  On a meeting type requiring the host's approval, moving a booking to a new
  time returns it to the gate rather than carrying the old answer across. The
  host agreed to a specific time, not to the invitee's standing right to pick
  another one, and a confirmed booking that can be silently moved anywhere is
  the gate with an obvious hole in it.

  So a reschedule on such a meeting type re-enters `"awaiting_approval"` with
  a fresh window, the provider event goes back to tentative, and the invitee
  is told a request was made rather than that their meeting has moved.
  """

  require Logger

  alias Tymeslot.Bookings.{CalendarJobs, Errors, Policy, ScheduleCheck, Validation}
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @typedoc """
  Parameters for rescheduling a meeting to a new time slot.

  `duration` is accepted for shape-compatibility with the booking form but is
  never used: the rescheduled meeting keeps the original meeting's persisted
  duration (see `prepare_new_times/2`), never the request's.
  """
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
  `:meeting_not_found` when the lookup fails, `:slot_taken` when a concurrent
  booking claims the new time first or the requested time is one the
  organiser's schedule never offers, or `:failed_to_update_meeting` when
  persisting the new time fails for any other reason) or an arbitrary
  policy/validation string from `Tymeslot.Bookings.Policy` or
  `Tymeslot.Bookings.Validation`.
  """
  @spec execute(String.t(), reschedule_params(), any(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, Errors.classified_error() | String.t()}
  def execute(meeting_uid, new_params, _form_data, organizer_user_id)
      when is_binary(meeting_uid) and is_integer(organizer_user_id) do
    meeting_type = fn meeting ->
      fetch_meeting_type(meeting.meeting_type_id, organizer_user_id)
    end

    with {:ok, original_meeting} <-
           MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id),
         :ok <- validate_can_reschedule(original_meeting),
         {:ok, new_times} <- prepare_new_times(new_params, original_meeting),
         {:ok, updated_meeting} <-
           apply_time_update_and_schedule_job(
             original_meeting,
             new_times,
             meeting_type.(original_meeting)
           ) do
      AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
      sync_provider_video_room(updated_meeting)
      announce(updated_meeting, original_meeting)
      {:ok, updated_meeting}
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      error -> error
    end
  end

  # Private functions

  defp apply_time_update_and_schedule_job(
         meeting,
         %{start_time: start_dt, end_time: end_dt, duration_minutes: _dur},
         meeting_type
       ) do
    # Booking a new time settles any pending organizer reschedule request, so
    # the slot becomes live again — clear the timestamp.
    #
    # Reminder sent-tracking is reset too: the reminder(s) already sent were
    # pinned to the old time, so they must not suppress the re-pinned
    # reminder jobs scheduled for the new time.
    attrs =
      Map.merge(
        %{
          start_time: start_dt,
          end_time: end_dt,
          reschedule_requested_at: nil,
          reminders_sent: [],
          reminder_email_sent: false
        },
        gate_attributes(meeting_type, start_dt)
      )

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
      {:error, :booking_limit_reached} -> {:error, :booking_limit_reached}
      {:error, :failed_to_update_meeting} -> {:error, :failed_to_update_meeting}
      {:error, _reason} -> {:error, :failed_to_update_meeting}
    end
  end

  # On an ungated meeting type `status` is left untouched: it tracks the booking
  # lifecycle (pending, awaiting_payment, confirmed, ...), which a reschedule
  # never changes there.
  #
  # On a gated one the reschedule *is* a new request, so the whole approval
  # record is reset rather than partially updated: a stale `approval_resolved_at`
  # would make the new request look answered, and a stale
  # `approval_nudge_sent_at` would suppress the nudge for a window that has not
  # been nudged. The deadline is computed from now and capped at the new start
  # time, exactly as an original booking's is.
  defp gate_attributes(meeting_type, start_time) do
    if Approval.required?(meeting_type) do
      requested_at = DateTime.truncate(Clock.utc_now(), :second)

      %{
        status: "awaiting_approval",
        approval_requested_at: requested_at,
        approval_deadline_at: Approval.deadline_for(meeting_type, requested_at, start_time),
        approval_resolved_at: nil,
        approval_nudge_sent_at: nil,
        decline_reason: nil
      }
    else
      %{}
    end
  end

  # A booking back in the gate has not been rescheduled from the invitee's
  # point of view — it has been re-requested. Sending the reschedule email
  # would tell them their meeting has moved to a time nobody has agreed to,
  # which is the confusion the whole feature exists to remove.
  defp announce(%{status: "awaiting_approval"} = updated, _original) do
    case Events.meeting_requested(updated) do
      {:ok, _result} ->
        Logger.info("Reschedule returned the booking to the approval gate",
          meeting_id: updated.id
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to send booking request notifications on reschedule",
          meeting_id: updated.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp announce(updated, original), do: send_reschedule_notifications(updated, original)

  defp validate_can_reschedule(meeting) do
    Policy.can_reschedule_meeting?(meeting)
  end

  # The rescheduled meeting keeps its meeting type, so the notice and window
  # rules re-checked here come from the same schedule the original booking used.
  #
  # The duration comes from the ORIGINAL meeting, never from `params`: a
  # reschedule moves a meeting in time, it is not an opportunity to change its
  # length, and `params.duration` is an attendee-supplied URL slug with no
  # binding to what the meeting actually is (this stays true even when the
  # meeting type has since been deleted and `fetch_meeting_type/2` falls back
  # to `nil`).
  defp prepare_new_times(params, meeting) do
    organizer_user_id = meeting.organizer_user_id
    meeting_type = fetch_meeting_type(meeting.meeting_type_id, organizer_user_id)
    duration_minutes = meeting.duration
    config = Policy.scheduling_config(organizer_user_id, meeting_type)

    with {:ok, {start_datetime, end_datetime}} <-
           Validation.parse_meeting_times(
             params.date,
             params.time,
             duration_minutes,
             params.user_timezone
           ),
         {:ok, date} <- Date.from_iso8601(params.date),
         :ok <- Validation.validate_booking_time(start_datetime, params.user_timezone, config),
         :ok <-
           ScheduleCheck.validate_slot_on_schedule(
             date,
             start_datetime,
             duration_minutes,
             params.user_timezone,
             config
           ) do
      {:ok,
       %{
         start_time: start_datetime,
         end_time: end_datetime,
         duration_minutes: duration_minutes
       }}
    else
      {:error, :slot_not_offered} -> {:error, :slot_taken}
      {:error, :slot_availability_unverifiable} -> {:error, :slot_taken}
      {:error, _reason} = error -> error
    end
  end

  # Ad-hoc meetings carry no meeting type; a nil resolves the organiser's
  # default schedule, which is the right rule set for them.
  defp fetch_meeting_type(nil, _organizer_user_id), do: nil

  defp fetch_meeting_type(meeting_type_id, organizer_user_id),
    do: MeetingTypes.get_meeting_type(meeting_type_id, organizer_user_id)

  defp update_meeting(meeting, attrs) do
    case Scheduling.update_meeting_with_conflict_check(meeting, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, :time_conflict} -> {:error, :slot_taken}
      {:error, :booking_limit_reached} -> {:error, :booking_limit_reached}
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
