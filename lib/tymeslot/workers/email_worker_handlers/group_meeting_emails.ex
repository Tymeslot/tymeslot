defmodule Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails do
  @moduledoc """
  Fan-out for a group meeting's meeting-level emails (the host's
  cancellation, the reminders, the host's reschedule request) and the
  per-seat jobs that fan-out dispatches.

  Solo meetings carry one attendee on the meeting row, so a single pair of
  organiser/attendee emails is enough. Group meetings carry one live
  `meeting_participants` row per booker, so every participant needs their
  own email. With `max_participants` in the hundreds, sending all of them
  inline from a single Oban job means one failed send discards the job and
  strands everyone after it, and a retry would duplicate the emails that
  already went out. Instead, the meeting-level job here is a dispatcher: it
  enqueues one independently-retryable per-seat job per participant (unique
  per seat and per logical email, see
  `Tymeslot.Emails.EmailScheduler.MeetingScheduler.schedule_seat_email/5`)
  plus sends the single organiser email inline, and returns `:ok`. A failed
  organiser send retries the whole dispatch, which is safe because
  re-enqueuing an already-unique per-seat job is a no-op.

  A seat's own lifecycle (booked, cancelled, moved) is
  `Tymeslot.Workers.EmailWorkerHandlers.SeatEmails`; both re-check the seat
  when the job runs through `Tymeslot.Workers.EmailWorkerHandlers.SeatJobs`.

  The organiser's copies are built by
  `Tymeslot.Emails.AppointmentBuilder.for_organizer_of_group/3`: named after
  the participant count in the organiser's own language, with their links
  pointing at the dashboard rather than at the public booking links, which
  are refused for a group meeting.
  """

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.SeatJobs

  # Bounds how many per-seat `Oban.insert/1` calls `dispatch_seat_jobs/2` runs
  # concurrently. Sequential inserts for a meeting near `max_participants` (in
  # the hundreds) can outrun `EmailWorker`'s 30-second timeout, which discards
  # rather than retries, stranding every participant queued after the
  # cut-off. Bounded concurrency keeps the wall-clock time well inside that
  # budget without reaching for `Oban.insert_all/2`: only the paid Smart
  # Engine deduplicates a bulk insert, so on the engine this project runs, a
  # bulk insert would silently drop the per-seat uniqueness guarantee the
  # whole retry story depends on.
  @dispatch_max_concurrency 20
  @dispatch_task_timeout_ms 5_000

  @meeting_started "Meeting already started"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason), do: reason == @meeting_started

  @doc """
  One live participant's copy of a whole-meeting cancellation. Dispatched by
  `send_group_cancellation_emails/2` so a failure sending to one participant
  cannot block or discard the rest. Sent only while the meeting is indeed
  cancelled, and only to a participant who still held their seat (one who
  left was told when they did).
  """
  @spec handle_seat_meeting_cancellation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_meeting_cancellation_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id
      }) do
    SeatJobs.with_seat(
      meeting_id,
      participant_id,
      "seat meeting cancellation email",
      {:cancelled, :live},
      &send_seat_meeting_cancellation_email/2
    )
  end

  @doc """
  One live participant's reminder. Dispatched by
  `send_group_reminder_emails/4` so a failure sending to one participant
  cannot block or discard the rest.

  Guarded the same way as the solo reminder handler
  (`MeetingEmails.handle_reminder_emails/1`): a void slot or a meeting that
  has already started discards rather than sends a now-misleading reminder.
  The seat handler needs its own copy of that guard because
  `cancel_reminder_emails/1` only sweeps pending `send_reminder_emails` jobs,
  not the `send_seat_reminder` jobs this dispatches: those can still be in
  flight when the meeting is cancelled or voided, or the seat cancelled.
  """
  @spec handle_seat_reminder_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_reminder_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id,
        "reminder_value" => reminder_value,
        "reminder_unit" => reminder_unit
      }) do
    SeatJobs.with_seat(
      meeting_id,
      participant_id,
      "seat reminder email",
      {:live_slot, :live},
      fn meeting, participant ->
        if meeting_started?(meeting) do
          {:discard, @meeting_started}
        else
          send_seat_reminder_email(meeting, participant, reminder_value, reminder_unit)
        end
      end
    )
  end

  @doc """
  One live participant's reschedule request. Dispatched by
  `send_group_reschedule_requests/2` so a failure sending to one participant
  cannot block or discard the rest.
  """
  @spec handle_seat_reschedule_request(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_reschedule_request(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id
      }) do
    SeatJobs.with_seat(
      meeting_id,
      participant_id,
      "seat reschedule request",
      {:not_cancelled, :live},
      &send_seat_reschedule_request/2
    )
  end

  @doc """
  Dispatches one cancellation job per live participant plus one organiser
  email sent inline (there is only ever one organiser, so a job buys it no
  independent retry benefit).
  """
  @spec send_group_cancellation_emails(MeetingSchema.t(), [Recipient.t()]) ::
          :ok | {:error, term()}
  def send_group_cancellation_emails(meeting, participants) do
    with :ok <-
           dispatch_seat_jobs(participants, fn recipient ->
             EmailScheduler.schedule_seat_meeting_cancellation_email(
               meeting.id,
               recipient.participant_id
             )
           end) do
      organizer_details =
        AppointmentBuilder.for_organizer_of_group(meeting, length(participants))

      meeting.organizer_email
      |> Config.email_service_module().send_cancellation_email_to_organizer(organizer_details)
      |> organizer_result("cancellation")
    end
  end

  @doc """
  Dispatches one reminder job per live participant plus one organiser
  reminder sent inline.
  """
  @spec send_group_reminder_emails(MeetingSchema.t(), [Recipient.t()], pos_integer(), String.t()) ::
          :ok | {:error, term()}
  def send_group_reminder_emails(meeting, participants, reminder_value, reminder_unit) do
    with :ok <-
           dispatch_seat_jobs(participants, fn recipient ->
             EmailScheduler.schedule_seat_reminder_email(
               meeting.id,
               recipient.participant_id,
               reminder_value,
               reminder_unit
             )
           end) do
      reminder = %{value: reminder_value, unit: reminder_unit}

      organizer_details =
        AppointmentBuilder.for_organizer_of_group(meeting, length(participants), reminder)

      meeting.organizer_email
      |> Config.email_service_module().send_appointment_reminder_to_organizer(organizer_details)
      |> organizer_result("reminder")
    end
  end

  @doc """
  Dispatches one reschedule-request job per live participant. The host
  asking to move a group meeting voids the slot for everybody on it, so
  everybody has to hear about it; there is no organiser email in this flow,
  since the host is the one making the request.

  Each seat job is named by the request's `reschedule_requested_at`, so a
  re-run of this dispatch cannot email a participant twice, while a later
  request is a new email.
  """
  @spec send_group_reschedule_requests(MeetingSchema.t(), [Recipient.t()]) ::
          :ok | {:error, term()}
  def send_group_reschedule_requests(meeting, participants) do
    requested_at =
      case meeting.reschedule_requested_at do
        %DateTime{} = at -> DateTime.to_iso8601(at)
        nil -> nil
      end

    dispatch_seat_jobs(participants, fn recipient ->
      EmailScheduler.schedule_seat_reschedule_request(
        meeting.id,
        recipient.participant_id,
        requested_at
      )
    end)
  end

  defp send_seat_meeting_cancellation_email(meeting, participant) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)

    recipient.email
    |> Config.email_service_module().send_cancellation_email_to_attendee(details)
    |> SeatJobs.send_result("cancellation", seat_metadata(meeting, participant))
  end

  # Rendered through the participant's own recipient overlay, so locale,
  # timezone and calendar entry are their own.
  defp send_seat_reminder_email(meeting, participant, reminder_value, reminder_unit) do
    recipient = Recipient.from_participant(participant)
    reminder = %{value: reminder_value, unit: reminder_unit}
    details = AppointmentBuilder.from_meeting(meeting, recipient, reminder)

    recipient.email
    |> Config.email_service_module().send_appointment_reminder_to_attendee(details)
    |> SeatJobs.send_result("reminder", seat_metadata(meeting, participant))
  end

  # Rendered through the participant's own recipient overlay, so the "pick a
  # new time" link moves their seat rather than the whole meeting.
  defp send_seat_reschedule_request(meeting, participant) do
    meeting
    |> Meetings.meeting_as_seen_by(Recipient.from_participant(participant))
    |> Config.email_service_module().send_reschedule_request()
    |> SeatJobs.send_result("reschedule request", seat_metadata(meeting, participant))
  end

  defp seat_metadata(meeting, participant),
    do: [meeting_id: meeting.id, participant_id: participant.id]

  # Schedules `schedule_fun` for every participant, bounded to
  # `@dispatch_max_concurrency` concurrent inserts so a meeting with hundreds
  # of participants cannot run the sequential-insert wall-clock time past
  # `EmailWorker`'s timeout. Each per-seat job is unique per seat and per
  # logical email, so re-running this on retry after a downstream (e.g.
  # organiser-email) failure cannot duplicate a job that was already
  # enqueued. A task that times out is treated as a failure (not silently
  # dropped), so the whole dispatch retries rather than losing that
  # participant.
  defp dispatch_seat_jobs(participants, schedule_fun) do
    results =
      Tymeslot.TaskSupervisor
      |> Tasks.async_stream_nolink(participants, schedule_fun,
        max_concurrency: @dispatch_max_concurrency,
        timeout: @dispatch_task_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
      end)

    if Enum.all?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, "Failed to schedule one or more seat email jobs"}
    end
  end

  # Preserves `:circuit_open` and `{:recipient_rejected, _}` through
  # `DeliveryOutcome.from_error/2` rather than flattening every failure into a
  # string, so `EmailWorker` can snooze past a provider outage or discard a
  # dead address instead of burning ordinary retries on either.
  defp organizer_result({:ok, _result}, _label), do: :ok

  defp organizer_result({:error, reason}, label),
    do: DeliveryOutcome.from_error(reason, "Failed to send organiser #{label} email")

  defp meeting_started?(meeting) do
    DateTime.compare(meeting.start_time, DateTime.utc_now()) != :gt
  end
end
