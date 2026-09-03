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

  That only applies, though, when the booking's current status is one the
  gate is meaningful for: `"confirmed"` (the host answered, and the reschedule
  asks them again) or `"awaiting_approval"` (a held request being moved before
  anyone has answered). A booking that never paid (`"awaiting_payment"`) or
  one whose window already lapsed (`"expired"`, already released and
  refunded) has nothing to gate; forcing either into `"awaiting_approval"`
  would let the host approve a booking nobody paid for, or one the invitee
  has already been refunded for. Their status is left untouched instead,
  exactly as an ungated meeting type's is.

  So a reschedule on such a meeting type, from one of those two statuses,
  re-enters `"awaiting_approval"` with a fresh window, the provider event
  goes back to tentative, and the invitee is told a request was made rather
  than that their meeting has moved.
  """

  require Logger

  alias Tymeslot.Bookings.{CalendarJobs, Errors, Policy, ScheduleCheck, Validation}
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Notifications.{Events, Orchestrator}
  alias Tymeslot.Repo
  alias Tymeslot.Utils.DateTimeUtils.Duration, as: UrlDuration
  alias Tymeslot.Workers.VideoSyncWorker

  @typedoc """
  Parameters for rescheduling a meeting to a new time slot.

  `duration` is accepted for shape-compatibility with the booking form but is
  never used: the rescheduled meeting keeps the original meeting's persisted
  duration (see `prepare_new_times/3`), never the request's.
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
         meeting_type <-
           fetch_meeting_type(
             original_meeting.meeting_type_id,
             organizer_user_id,
             original_meeting.duration
           ),
         {:ok, new_times} <- prepare_new_times(new_params, original_meeting, meeting_type),
         {:ok, updated_meeting} <-
           apply_time_update_and_schedule_job(original_meeting, new_times, meeting_type) do
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
        gate_attributes(meeting_type, start_dt, meeting)
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

  # On an ungated meeting type, or on a gated one whose current status the
  # gate is not meaningful for (see the module doc), `status` is left
  # untouched: it tracks the booking lifecycle (pending, awaiting_payment,
  # confirmed, ...), which a reschedule never changes there.
  #
  # On a gated one being moved from `"confirmed"` or `"awaiting_approval"`,
  # the reschedule *is* a new request, so the whole approval record is reset
  # rather than partially updated: a stale `approval_resolved_at` would make
  # the new request look answered, a stale `approval_nudge_sent_at` would
  # suppress the nudge for a window that has not been nudged, and a stale
  # `announced_at` would leave `Events.meeting_created/1`'s once-per-meeting
  # claim (`MeetingQueries.claim_announcement/1`) already spent — the host's
  # second approval would then win the DB transition but lose the fan-out,
  # so the invitee gets no confirmation email, no reminders and no
  # `meeting.created` webhook for the new time. The deadline is computed from
  # now and capped at the new start time, exactly as an original booking's is.
  #
  # A meeting type can also stop requiring approval while one of its bookings
  # is still held. Moving that booking must not leave it stranded in the
  # gate with a deadline computed against its old start time: nothing recaps
  # it, and `Approval.approve/1` refuses a meeting whose slot has passed, so
  # it would sit held until the expiry sweep with no way to be approved.
  # There is no gate left to hold it in, so the reschedule confirms it
  # outright instead, exactly as a fresh booking against the now-ungated type
  # would be.
  defp gate_attributes(meeting_type, start_time, meeting) do
    cond do
      Approval.required?(meeting_type) and reenters_gate?(meeting) ->
        requested_at = DateTime.truncate(Clock.utc_now(), :second)

        %{
          status: "awaiting_approval",
          approval_requested_at: requested_at,
          approval_deadline_at: Approval.deadline_for(meeting_type, requested_at, start_time),
          approval_resolved_at: nil,
          approval_declined_at: nil,
          approval_nudge_sent_at: nil,
          decline_reason: nil,
          announced_at: nil
        }

      not Approval.required?(meeting_type) and meeting.status == "awaiting_approval" ->
        %{status: "confirmed", approval_resolved_at: DateTime.truncate(Clock.utc_now(), :second)}

      true ->
        %{}
    end
  end

  # Only these two statuses mean the invitee is expecting a decision from the
  # host: `"confirmed"` (the host already agreed, and the reschedule asks
  # again) or `"awaiting_approval"` (a held request being moved before anyone
  # has answered). `"awaiting_payment"` never reached the host in the first
  # place, and `"expired"` already lapsed and was refunded by
  # `Meetings.Approval` — reviving either into the gate would let the host
  # approve a booking nobody paid for, or one the invitee was already given
  # their money back for.
  defp reenters_gate?(%{status: status}), do: status in ["confirmed", "awaiting_approval"]

  # A booking back in the gate has not been rescheduled from the invitee's
  # point of view — it has been re-requested. Sending the reschedule email
  # would tell them their meeting has moved to a time nobody has agreed to,
  # which is the confusion the whole feature exists to remove.
  #
  # Known gap: when the booking being re-gated came from `"confirmed"`, the
  # invitee's calendar client may already hold an event from the original
  # confirmation's ICS attachment (`AppointmentConfirmation`'s
  # `IcsGenerator.generate_ics_attachment/2`). The request email sent below
  # (`BookingRequestReceived`) carries no calendar attachment, so that entry
  # is left showing the old, no-longer-accurate confirmed time until the host
  # answers again — approval re-sends a fresh confirmation ICS for the new
  # time (self-healing), but a decline or expiry's outcome email does not
  # correct it either. Fixing this needs a calendar-only correction path
  # analogous to `Tymeslot.Meetings.AttendeeNotifications`'s ICS handling,
  # which lives outside this module's booking-email templates and is left
  # for that work rather than bolted on here.
  defp announce(%{status: "awaiting_approval"} = updated, _original) do
    cancel_stale_reminders(updated)

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

  # `gate_attributes/3` confirms a held request outright when its meeting
  # type stopped requiring approval since the request was made — see the
  # comment there. The nudge and expiry jobs armed for that request no longer
  # apply to a confirmed booking, so they are cleared here exactly as
  # `Approval.approve/1` clears them on an ordinary approval, and the invitee
  # is told the same way any other reschedule tells them.
  defp announce(%{status: "confirmed"} = updated, %{status: "awaiting_approval"} = original) do
    Orchestrator.cancel_request_notifications(updated)
    send_reschedule_notifications(updated, original)
  end

  defp announce(updated, original), do: send_reschedule_notifications(updated, original)

  # A booking re-entering the gate must not carry reminders pinned to the
  # time it was confirmed for before: left alone, they would fire and remind
  # the attendee about a meeting nobody has agreed to yet. `Approval.approve/1`
  # re-schedules them in full, through the same pipeline an ordinary
  # confirmation uses, once the host answers — so this only ever needs to
  # clear, never to re-pin.
  defp cancel_stale_reminders(meeting) do
    case Orchestrator.cancel_reminder_notifications(meeting) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to cancel stale reminder jobs on reschedule",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
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
  #
  # `meeting_type` is resolved once by the caller and threaded through here
  # rather than re-fetched: two reads of the same row leave a window in which
  # a host edit between them could be answered differently by each call.
  defp prepare_new_times(params, meeting, meeting_type) do
    organizer_user_id = meeting.organizer_user_id

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
