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

  alias Tymeslot.Availability.Offer

  alias Tymeslot.Bookings.{
    CalendarCheck,
    CalendarJobs,
    Errors,
    Policy,
    RescheduleLocation,
    ScheduleCheck,
    Validation
  }

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Notifications.{Events, GuestNotifications, Orchestrator}
  alias Tymeslot.Repo
  alias Tymeslot.Utils.DateTimeUtils.Duration, as: UrlDuration
  alias Tymeslot.Workers.VideoSyncWorker

  @typedoc """
  Parameters for rescheduling a meeting to a new time slot.

  `duration` is accepted for shape-compatibility with the booking form but is
  never used: the rescheduled meeting keeps the original meeting's persisted
  duration (see `prepare_new_times/3`), never the request's.

  `location_option_id`, `location_phone` and `location_video_integration_id`
  are the booker's location choice, applied only when it differs from the meeting's current location (see
  `Tymeslot.Bookings.RescheduleLocation`).
  """
  @type reschedule_params :: %{
          required(:date) => String.t(),
          required(:time) => String.t(),
          required(:duration) => integer() | String.t(),
          required(:user_timezone) => String.t(),
          optional(:location_option_id) => String.t() | nil,
          optional(:location_phone) => String.t() | nil,
          optional(:location_video_integration_id) => integer() | String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Reschedules an existing meeting.

  This includes:
  1. Validating the new time, against the organiser's schedule and their
     connected calendars
  2. Cancelling the original calendar event
  3. Updating meeting times with conflict checking, together with any video
     join URLs that are only valid relative to the meeting time, and the
     location when the booker chose a new one
  4. Creating new calendar event
  5. Deleting a video room the new location no longer uses, and creating one
     it does
  6. Sending rescheduling notifications, which a room being created sends
     instead once its join link exists

  The `organizer_user_id` is required. The meeting lookup is scoped to that
  owner, preventing IDOR attacks from the public booking flow.

  Returns `{:ok, meeting}` or `{:error, reason}`, where `reason` is either a
  semantic atom (`Tymeslot.Bookings.Errors.classified_error/0` — currently
  `:meeting_not_found` when the lookup fails, `:slot_taken` when a concurrent
  booking claims the new time first, when the requested time is one the
  organiser's schedule never offers, or when their connected calendar has
  since been blocked over it, or `:failed_to_update_meeting` when
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
         config <- Policy.scheduling_config(original_meeting.organizer_user_id, meeting_type),
         {:ok, new_times} <-
           prepare_new_times(new_params, original_meeting, meeting_type, config),
         :ok <- verify_calendar_free(original_meeting, new_times, config),
         {:ok, updated_meeting} <-
           apply_time_update_and_schedule_job(
             original_meeting,
             new_times,
             meeting_type,
             RescheduleLocation.attributes(original_meeting, meeting_type, new_params)
           ) do
      after_commit(updated_meeting, original_meeting)
      {:ok, updated_meeting}
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      error -> error
    end
  end

  # Private functions

  # Everything a committed reschedule sets off outside the meeting row: fresh
  # availability, the provider side of any room the move left behind or
  # moved, and the emails.
  defp after_commit(updated_meeting, original_meeting) do
    AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
    RescheduleLocation.release_abandoned_room(updated_meeting, original_meeting)
    sync_provider_video_room(updated_meeting)
    announce(updated_meeting, original_meeting)
  end

  defp apply_time_update_and_schedule_job(
         meeting,
         %{start_time: start_dt, end_time: end_dt, duration_minutes: _dur},
         meeting_type,
         location_attrs
       ) do
    # Booking a new time settles any pending organizer reschedule request, so
    # the slot becomes live again — clear the timestamp.
    #
    # Reminder sent-tracking is reset too: the reminder(s) already sent were
    # pinned to the old time, so they must not suppress the re-pinned
    # reminder jobs scheduled for the new time.
    #
    # The location lands in the same write as the times, so the calendar job
    # scheduled below already carries it.
    #
    # Join links that expire relative to the meeting time (Jitsi tokens) are
    # rebuilt for the new time here, before the write, rather than in
    # `VideoSyncWorker`: the reschedule emails below are rendered from the
    # meeting this write returns, and the calendar and webhook jobs read the
    # row it commits, so a link refreshed any later would already have been
    # sent out stale. Writing them with the new time also leaves no moment
    # where the row pairs the new time with the old links. Building them is
    # local computation, and a failure keeps the stored links rather than
    # failing the reschedule.
    #
    # The new time is a new revision of the calendar entry, so `ical_sequence`
    # moves on. It records the revision of the last calendar entry sent out,
    # the same meaning `AttendeeNotifications.Worker` gives it when the host
    # moves the event in their own calendar: the reschedule email carries this
    # value, and anything sent later (another reschedule, a cancellation, a
    # host-side change) goes past it. Left at 0, every reschedule sent
    # SEQUENCE 1 again and calendar clients had only DTSTAMP to tell the
    # entries apart.
    #
    # A reschedule that re-enters the approval gate sends no calendar entry at
    # all (see `announce/2`), so the bump reserves the revision rather than
    # announcing it: the confirmation ICS the host's approval sends carries
    # this value, and nothing else has used it in the meantime. A request that
    # is declined or expires simply leaves the revision unspent, which costs
    # nothing: SEQUENCE has to rise, not to run consecutively.
    attrs =
      %{
        start_time: start_dt,
        end_time: end_dt,
        reschedule_requested_at: nil,
        reminders_sent: [],
        reminder_email_sent: false,
        ical_sequence: meeting.ical_sequence + 1
      }
      |> Map.merge(gate_attributes(meeting_type, start_dt, meeting))
      |> Map.merge(VideoRooms.refreshed_join_url_attrs(meeting, start_dt))
      |> Map.merge(location_attrs)

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
  # so the invitee gets no reminders for the new time and the integration
  # channels never hear that it moved. Clearing it costs nothing that is
  # needed later: `first_announced_at` keeps the permanent record that this
  # booking was once a live meeting, which is what `Approval` reads when it
  # decides whether releasing the request refunds it, and what the claim reads
  # to announce the approval to webhooks, Telegram and Slack as
  # `meeting.rescheduled` rather than a second `meeting.created`. The
  # deadline is computed from now and capped at the new start time, exactly
  # as an original booking's is.
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
    gate_type = gate_meeting_type(meeting_type, meeting)

    cond do
      Approval.required?(gate_type) and reenters_gate?(meeting) ->
        requested_at = DateTime.truncate(Clock.utc_now(), :second)

        %{
          status: "awaiting_approval",
          approval_requested_at: requested_at,
          approval_deadline_at: Approval.deadline_for(gate_type, requested_at, start_time),
          approval_resolved_at: nil,
          approval_declined_at: nil,
          approval_nudge_sent_at: nil,
          decline_reason: nil,
          announced_at: nil
        }

      not Approval.required?(gate_type) and meeting.status == "awaiting_approval" ->
        %{status: "confirmed", approval_resolved_at: DateTime.truncate(Clock.utc_now(), :second)}

      true ->
        %{}
    end
  end

  # An ad-hoc booking — dragged onto the dashboard calendar, or produced by
  # confirming a poll — carries no `meeting_type_id`, and `Approval.required?/1`
  # already states the rule for it: no meeting type means no gate. Creation
  # honours that (`Bookings.Policy` resolves the type by id and gets `nil`), so
  # a reschedule must too.
  #
  # It does not fall out of `fetch_meeting_type/3`, which answers a different
  # question: with no id to look up, it matches a type by duration slug so that
  # the reschedule enforces the same *schedule* the grid the invitee saw was
  # drawn from. Every account is seeded with types named "15 Minutes" and
  # "30 Minutes", whose slugs are exactly what that lookup builds, so a
  # 30-minute ad-hoc booking reliably resolves the host's stock 30-minute type.
  # Reading `requires_approval` off it would send a booking made under no
  # meeting type into a gate on the strength of a setting the host ticked
  # somewhere else entirely, where it could then sit unanswered and be expired
  # by the sweep.
  defp gate_meeting_type(_meeting_type, %{meeting_type_id: nil}), do: nil
  defp gate_meeting_type(meeting_type, _meeting), do: meeting_type

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
  # answers again. Both outcomes heal it: the reschedule notice approval now
  # sends carries an ICS for the new time stamped with the `ical_sequence`
  # this reschedule advanced, so the client supersedes the entry it holds
  # rather than judging two entries of equal revision by their DTSTAMP, and a
  # decline or an expiry cancels the booking, whose outcome email
  # (`BookingRequestOutcome`) carries a cancellation ICS for it. Correcting
  # the entry while the request is still open would need a calendar-only path
  # analogous to `Tymeslot.Meetings.AttendeeNotifications`'s ICS handling,
  # which lives outside this module's booking-email templates and is left for
  # that work rather than bolted on here.
  defp announce(%{status: "awaiting_approval"} = updated, original) do
    cancel_stale_reminders(updated)
    GuestNotifications.prepare_for_reapproval(updated)

    case Events.meeting_requested(updated, previous_start_opts(updated, original)) do
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
  # comment there. That booking is a new confirmed meeting nobody has ever
  # been told about: it was held from the moment it was created, so it has no
  # confirmation email, no ICS, no video room, no reminders and an unclaimed
  # `announced_at`. Telling the invitee their meeting "has been rescheduled"
  # would be the only thing they ever heard about it.
  #
  # So this takes the approval side effects rather than the reschedule ones,
  # through the very function `Approval.approve/1` uses
  # (`Approval.activate_confirmed/1`): the request notifications are cancelled,
  # the tentative calendar hold is flipped to a real event, and the meeting is
  # activated with its video room. Sharing that function rather than repeating
  # its three steps here is what keeps this path from drifting away from the
  # approval it is standing in for.
  #
  # The duplicate calendar "update" job this schedules on top of
  # `apply_time_update_and_schedule_job/3`'s own is harmless:
  # `CalendarJobs.schedule_job/2` is uniqueness-guarded and reports the second
  # insert as `:already_scheduled`.
  defp announce(%{status: "confirmed"} = updated, %{status: "awaiting_approval"}) do
    Approval.activate_confirmed(updated)
  end

  # A room on a newly chosen video integration, or one still on its way when
  # the reschedule came, is scheduled here rather than alongside the release,
  # because only this path confirms nothing on its own: the two clauses above
  # leave room creation to the approval that confirms the booking. When a room
  # is on its way, its job sends these notifications once the join link
  # exists.
  defp announce(updated, original) do
    case RescheduleLocation.create_room(updated, original) do
      :scheduled -> :ok
      :not_scheduled -> send_reschedule_notifications(updated, original)
    end
  end

  # A booking confirmed before (`first_announced_at`) is being moved, and its
  # request emails say so; showing the time it was moved from needs the
  # original, which nothing else keeps once the new time is saved.
  defp previous_start_opts(%{first_announced_at: %DateTime{}}, %{start_time: %DateTime{} = start}),
       do: [previous_start_time: start]

  defp previous_start_opts(_updated, _original), do: []

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
  # `ScheduleCheck`, however, is given the duration the reschedule page's grid
  # is stepped by (`Offer.duration_minutes/2`): the CURRENT meeting type's,
  # falling back to the persisted one only for an unresolved type. Re-deriving
  # the grid with a stale duration after a host edits the type would refuse
  # slots the page just offered. Only the check's step size changes; the
  # meeting's own duration, computed below via `duration_minutes`, never does.
  #
  # `meeting_type` and `config` are resolved once by the caller and threaded
  # through here rather than re-fetched: two reads of the same rows leave a
  # window in which a host edit between them could be answered differently by
  # each call, and `verify_calendar_free/3` needs the same buffer and notice
  # rules this check was made against.
  defp prepare_new_times(params, meeting, meeting_type, config) do
    organizer_user_id = meeting.organizer_user_id

    duration_minutes = meeting.duration

    schedule_check_duration_minutes = Offer.duration_minutes(meeting_type, duration_minutes)

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

  # The schedule check above re-derives the organiser's windows and breaks, but
  # it computes them against an empty event list by design
  # (`Calculate.offers_slot/6`), and the write below only looks at Tymeslot's
  # own meetings. Without this, nothing on the reschedule path ever consults the
  # host's connected calendar: a time the host blocked in Google, Outlook or
  # CalDAV after the reschedule page rendered, or one the page's cached event
  # list never knew about, could still be moved onto. The booking submit has
  # re-read the calendar at this point for as long as it has existed; this is
  # the same check, through the same module.
  #
  # The meeting being moved is excluded, because its own event is sitting in
  # that calendar: counting it would refuse every move onto a time overlapping
  # or (through the buffer) adjacent to the slot it already occupies, so a
  # booking could not be nudged by fifteen minutes.
  #
  # Both refusals collapse to `:slot_taken`, exactly as `Create` classifies
  # them, so the invitee is returned to the grid to pick another time rather
  # than shown a distinction they cannot act on.
  defp verify_calendar_free(meeting, %{start_time: start_time, end_time: end_time}, config) do
    slot = %{
      organizer_user_id: meeting.organizer_user_id,
      start_datetime: start_time,
      end_datetime: end_time
    }

    case CalendarCheck.enforce(slot, config, exclude: meeting) do
      :ok -> :ok
      {:error, _reason} -> {:error, :slot_taken}
    end
  end

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
  # locally, and its join URLs either stay valid across the move or were
  # already rebuilt for the new time by
  # `apply_time_update_and_schedule_job/3`. Whether an integration can still
  # reach the room is decided inside the job by `IntegrationResolver`, so a
  # meeting whose integration was disconnected is still synced rather than left
  # advertising the old time.
  #
  # A room the reschedule detached for a new location has no `video_room_id`
  # left on `updated`, so it is skipped here; `RescheduleLocation` releases it.
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
