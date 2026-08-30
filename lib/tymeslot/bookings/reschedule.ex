defmodule Tymeslot.Bookings.Reschedule do
  @moduledoc """
  Orchestrates the booking rescheduling process.
  Handles meeting time updates, calendar event migration, and notifications.
  """

  require Logger

  alias Tymeslot.Bookings.{CalendarJobs, Errors, Policy, ScheduleCheck, Validation}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Utils.DateTimeUtils.Duration, as: UrlDuration
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
    with {:ok, original_meeting} <-
           MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id),
         :ok <- validate_can_reschedule(original_meeting),
         {:ok, new_times} <- prepare_new_times(new_params, original_meeting),
         {:ok, updated_meeting} <- apply_time_update_and_schedule_job(original_meeting, new_times) do
      AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
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
      {:error, :booking_limit_reached} -> {:error, :booking_limit_reached}
      {:error, :failed_to_update_meeting} -> {:error, :failed_to_update_meeting}
      {:error, _reason} -> {:error, :failed_to_update_meeting}
    end
  end

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
  # meeting type has since been deleted and `fetch_meeting_type/3` falls back
  # to `nil`).
  #
  # `ScheduleCheck`, however, is given the CURRENT meeting type's duration
  # (`schedule_check_duration_minutes/2`) rather than the persisted one: the
  # reschedule page's grid is stepped by the current meeting type's duration
  # (`AvailabilityHelpers.duration_minutes/1`), so re-deriving the grid with a
  # stale duration after a host edits the type would refuse slots the page
  # just offered. Only the check's step size changes; the meeting's own
  # duration, computed below via `duration_minutes`, never does.
  defp prepare_new_times(params, meeting) do
    organizer_user_id = meeting.organizer_user_id

    meeting_type =
      fetch_meeting_type(meeting.meeting_type_id, organizer_user_id, meeting.duration)

    duration_minutes = meeting.duration

    schedule_check_duration_minutes =
      schedule_check_duration_minutes(meeting_type, duration_minutes)

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
             schedule_check_duration_minutes,
             params.user_timezone,
             config,
             organizer_user_id
           ) do
      {:ok,
       %{
         start_time: start_datetime,
         end_time: end_datetime,
         duration_minutes: duration_minutes
       }}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, Errors.classify_schedule_check_reason(reason) || reason}

      {:error, _reason} = error ->
        error
    end
  end

  # Mirrors `TymeslotWeb.Live.Scheduling.AvailabilityHelpers.duration_minutes/1`:
  # the resolved meeting type's current duration is authoritative for grid
  # generation, and only an unresolved type falls back to the persisted
  # duration.
  defp schedule_check_duration_minutes(%{duration_minutes: minutes}, _persisted_duration_minutes)
       when is_integer(minutes),
       do: minutes

  defp schedule_check_duration_minutes(_meeting_type, persisted_duration_minutes),
    do: persisted_duration_minutes

  # Ad-hoc meetings (no `meeting_type_id`) mirror the reschedule page's own
  # fallback (`ThemeFlow.resolve_meeting_type_for_duration/2`): resolve by a
  # duration match rather than jumping straight to the organiser's default
  # schedule, so the enforcement side checks the same schedule the displayed
  # grid was drawn from. Only when no type matches that duration does this
  # resolve to `nil`, which in turn falls back to the default schedule.
  defp fetch_meeting_type(nil, organizer_user_id, duration_minutes) do
    duration_minutes
    |> UrlDuration.format_for_url()
    |> MeetingTypes.normalize_duration_slug()
    |> then(&MeetingTypes.find_by_duration_string(organizer_user_id, &1))
  end

  defp fetch_meeting_type(meeting_type_id, organizer_user_id, _duration_minutes),
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
