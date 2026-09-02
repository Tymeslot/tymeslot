defmodule Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails do
  @moduledoc """
  Fan-out for group-meeting cancellation, reminder and reschedule-request
  emails, plus the single-recipient sends the per-seat jobs it dispatches
  perform.

  Solo meetings carry one attendee on the meeting row, so a single pair of
  organiser/attendee emails is enough. Group meetings carry one live
  `meeting_participants` row per booker, so every participant needs their
  own email. With `max_participants` in the hundreds, sending all of them
  inline from a single Oban job means one failed send discards the job and
  strands everyone after it — a retry would duplicate the emails that
  already went out. Instead, the meeting-level job here is a dispatcher: it
  enqueues one independently-retryable per-seat job per participant (same
  `keys: [:action, :meeting_id, :participant_id]` uniqueness as the
  confirmation path) plus sends the single organiser email inline, and
  returns `:ok`. Oban then gives per-recipient retry and visibility for
  free; a failed organiser send retries the whole dispatch, which is safe
  because re-enqueuing an already-unique per-seat job is a no-op.

  It also owns the seat lifecycle itself — the confirmation, cancellation and
  reschedule emails for one booker's own seat, as opposed to that booker's
  copy of a whole-meeting event.

  Split out of `Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails`, which
  still owns the solo-meeting paths and the meeting-level bookkeeping
  (`process_email_results/4`), and shares its `with_meeting/3` lookup and
  `send_guest_confirmations/4` send loop with this module.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  # Bounds how many per-seat `Oban.insert/1` calls `dispatch_seat_jobs/2` runs
  # concurrently. Sequential inserts for a meeting near `max_participants` (in
  # the hundreds) can outrun `EmailWorker`'s 30-second timeout, which discards
  # rather than retries — stranding every participant queued after the
  # cut-off. Bounded concurrency keeps the wall-clock time well inside that
  # budget without reaching for `Oban.insert_all/2`: only the paid Smart
  # Engine deduplicates a bulk insert, so on the engine this project runs, a
  # bulk insert would silently drop the per-seat uniqueness guarantee the
  # whole retry story depends on.
  @dispatch_max_concurrency 20
  @dispatch_task_timeout_ms 5_000

  @doc """
  One live participant's copy of a whole-meeting cancellation. Dispatched by
  `send_group_cancellation_emails/2` so a failure sending to one participant
  cannot block or discard the rest.
  """
  @spec handle_seat_meeting_cancellation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_meeting_cancellation_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id
      }) do
    with_meeting_and_participant(
      meeting_id,
      participant_id,
      "seat meeting cancellation email",
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
  not the `send_seat_reminder` jobs this dispatches — those can still be
  in flight when the meeting is cancelled or voided.
  """
  @spec handle_seat_reminder_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_reminder_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id,
        "reminder_value" => reminder_value,
        "reminder_unit" => reminder_unit
      }) do
    MeetingEmails.with_meeting(meeting_id, "seat reminder email", fn meeting ->
      cond do
        MeetingState.slot_void?(meeting) ->
          Logger.info("Skipping seat reminder email for inactive meeting",
            meeting_id: meeting_id,
            participant_id: participant_id,
            status: meeting.status
          )

          {:discard, "Meeting #{meeting.status}"}

        meeting_started?(meeting) ->
          Logger.info("Skipping seat reminder email - meeting already started",
            meeting_id: meeting_id,
            participant_id: participant_id,
            start_time: meeting.start_time
          )

          {:discard, "Meeting already started"}

        true ->
          case find_live_recipient(meeting, participant_id) do
            nil ->
              {:discard, "Participant not found or cancelled"}

            recipient ->
              send_seat_reminder_email(meeting, recipient, reminder_value, reminder_unit)
          end
      end
    end)
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
    with_meeting_and_participant(
      meeting_id,
      participant_id,
      "seat reschedule request",
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
        meeting
        |> AppointmentBuilder.from_meeting()
        |> Map.put(:attendee_name, participant_count_label(participants))

      send_organizer_email(
        Config.email_service_module().send_cancellation_email_to_organizer(
          meeting.organizer_email,
          organizer_details
        ),
        "cancellation"
      )
    end
  end

  @doc """
  One cancellation email to a single live participant, telling them the
  whole meeting was cancelled. Performed by the per-seat job dispatched from
  `send_group_cancellation_emails/2`.
  """
  @spec send_seat_meeting_cancellation_email(MeetingSchema.t(), Recipient.t()) ::
          :ok | {:error, term()}
  def send_seat_meeting_cancellation_email(meeting, recipient) do
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)

    result =
      Config.email_service_module().send_cancellation_email_to_attendee(recipient.email, details)

    send_seat_result(result, "cancellation", meeting.id, recipient.participant_id)
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
        meeting
        |> AppointmentBuilder.from_meeting(reminder)
        |> Map.put(:attendee_name, participant_count_label(participants))

      send_organizer_email(
        Config.email_service_module().send_appointment_reminder_to_organizer(
          meeting.organizer_email,
          organizer_details
        ),
        "reminder"
      )
    end
  end

  @doc """
  One reminder email to a single live participant, rendered through their
  own recipient overlay so locale and timezone are their own. Performed by
  the per-seat job dispatched from `send_group_reminder_emails/4`.
  """
  @spec send_seat_reminder_email(
          MeetingSchema.t(),
          Recipient.t(),
          pos_integer(),
          String.t()
        ) ::
          :ok | {:error, term()}
  def send_seat_reminder_email(meeting, recipient, reminder_value, reminder_unit) do
    reminder = %{value: reminder_value, unit: reminder_unit}
    details = AppointmentBuilder.from_meeting(meeting, recipient, reminder)

    result =
      Config.email_service_module().send_appointment_reminder_to_attendee(
        recipient.email,
        details
      )

    send_seat_result(result, "reminder", meeting.id, recipient.participant_id)
  end

  @doc """
  Dispatches one reschedule-request job per live participant. The host
  asking to move a group meeting voids the slot for everybody on it, so
  everybody has to hear about it; there is no organiser email in this flow,
  since the host is the one making the request.
  """
  @spec send_group_reschedule_requests(MeetingSchema.t(), [Recipient.t()]) ::
          :ok | {:error, term()}
  def send_group_reschedule_requests(meeting, participants) do
    dispatch_seat_jobs(participants, fn recipient ->
      EmailScheduler.schedule_seat_reschedule_request(meeting.id, recipient.participant_id)
    end)
  end

  @doc """
  One reschedule request to a single live participant, rendered through
  their own recipient overlay so the "pick a new time" link moves their seat
  rather than the whole meeting. Performed by the per-seat job dispatched
  from `send_group_reschedule_requests/2`.
  """
  @spec send_seat_reschedule_request(MeetingSchema.t(), Recipient.t()) :: :ok | {:error, term()}
  def send_seat_reschedule_request(meeting, recipient) do
    meeting
    |> Meetings.meeting_as_seen_by(recipient)
    |> Config.email_service_module().send_reschedule_request()
    |> send_seat_result("reschedule request", meeting.id, recipient.participant_id)
  end

  # Schedules `schedule_fun` for every participant, bounded to
  # `@dispatch_max_concurrency` concurrent inserts so a meeting with hundreds
  # of participants cannot run the sequential-insert wall-clock time past
  # `EmailWorker`'s timeout. Each per-seat job is uniqued on
  # `(action, meeting_id, participant_id)`, so re-running this on retry after
  # a downstream (e.g. organiser-email) failure cannot duplicate a job that
  # was already enqueued — a task that times out is treated as a failure
  # (not silently dropped), so the whole dispatch retries rather than losing
  # that participant.
  defp dispatch_seat_jobs(participants, schedule_fun) do
    results =
      Tymeslot.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(participants, schedule_fun,
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
  defp send_organizer_email({:ok, _result}, _label), do: :ok

  defp send_organizer_email({:error, reason}, label),
    do: DeliveryOutcome.from_error(reason, "Failed to send organiser #{label} email")

  defp send_seat_result({:ok, _result}, _label, _meeting_id, _participant_id), do: :ok

  defp send_seat_result({:error, reason}, label, meeting_id, participant_id) do
    Logger.error("Failed to send seat email",
      label: label,
      meeting_id: meeting_id,
      participant_id: participant_id,
      error: inspect(reason)
    )

    DeliveryOutcome.from_error(reason, "Failed to send seat #{label} email")
  end

  # Fetches the meeting and its live participant and runs `fun` with both, or
  # discards the job with a consistent log line when either no longer exists
  # or the participant has since cancelled their seat — a seat cancelled
  # between dispatch and this job running must not still receive the seat
  # copy of a whole-meeting cancellation or a reschedule request.
  defp with_meeting_and_participant(meeting_id, participant_id, action, fun) do
    MeetingEmails.with_meeting(meeting_id, action, fn meeting ->
      case find_live_recipient(meeting, participant_id) do
        nil -> {:discard, "Participant not found or cancelled"}
        recipient -> fun.(meeting, recipient)
      end
    end)
  end

  @spec handle_seat_confirmation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_confirmation_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id
      }) do
    MeetingEmails.with_meeting(meeting_id, "seat confirmation emails", fn meeting ->
      case find_live_recipient(meeting, participant_id) do
        nil -> {:discard, "Participant not found or cancelled"}
        recipient -> send_seat_confirmation_emails(meeting, recipient)
      end
    end)
  end

  @spec handle_seat_cancellation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_cancellation_emails(
        %{"meeting_id" => meeting_id, "participant_id" => participant_id} = args
      ) do
    MeetingEmails.with_meeting(meeting_id, "seat cancellation emails", fn meeting ->
      case ParticipantQueries.get(participant_id) do
        {:ok, participant} ->
          notify_organizer? = Map.get(args, "notify_organizer", true)
          send_seat_cancellation_emails(meeting, participant, notify_organizer?)

        {:error, :not_found} ->
          {:discard, "Participant not found"}
      end
    end)
  end

  @spec handle_seat_reschedule_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_reschedule_emails(
        %{"meeting_id" => meeting_id, "participant_id" => participant_id} = args
      ) do
    MeetingEmails.with_meeting(meeting_id, "seat reschedule emails", fn meeting ->
      with {:ok, participant} <- ParticipantQueries.get(participant_id),
           {:ok, old_event} <- parse_old_event(args) do
        send_seat_reschedule_emails(meeting, participant, old_event)
      else
        {:error, :not_found} -> {:discard, "Participant not found"}
        {:error, :invalid_snapshot} -> {:discard, "Invalid old-event snapshot"}
      end
    end)
  end

  # A primary-key fetch, not a scan of `Meetings.recipients/1`'s full live
  # list: every seat handler above resolves exactly one participant, so
  # loading every live participant on the meeting to find it (as this used
  # to) is wasted work that grows with `max_participants`. The meeting-id
  # check guards against a job whose `participant_id` belongs to a different
  # meeting ever being treated as live here.
  defp find_live_recipient(meeting, participant_id) do
    case ParticipantQueries.get(participant_id) do
      {:ok, %{cancelled_at: nil, meeting_id: meeting_id} = participant} ->
        if meeting_id == meeting.id, do: Recipient.from_participant(participant)

      _not_found_or_cancelled ->
        nil
    end
  end

  # One participant's confirmation plus the organiser's per-seat notification.
  # Idempotency is job-level (no sent flags on participants): a full failure
  # retries, a partial failure discards so the retry cannot duplicate the
  # email that already went out — mirroring the cancellation-email semantics.
  defp send_seat_confirmation_emails(meeting, recipient) do
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    organizer_details = AppointmentBuilder.from_meeting(meeting)
    email_service = Config.email_service_module()

    organizer_result =
      email_service.send_appointment_confirmation_to_organizer(
        organizer_details.organizer_email,
        organizer_details
      )

    attendee_result =
      email_service.send_appointment_confirmation_to_attendee(recipient.email, details)

    send_participant_guest_confirmations(meeting, recipient, details, email_service)

    DeliveryOutcome.from_dual_send(
      "seat confirmation",
      [meeting_id: meeting.id, participant_id: recipient.participant_id],
      organizer_result,
      attendee_result
    )
  end

  # The cancelled participant is looked up by id, not through `recipients/1`,
  # precisely because they are no longer live. The attendee email is the
  # existing `AppointmentCancellation` template, whose cancel ICS already
  # bumps `ical_sequence + 1` on the meeting UID, removing the event from
  # that participant's calendar copy only.
  defp send_seat_cancellation_emails(meeting, participant, notify_organizer?) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    email_service = Config.email_service_module()

    attendee_result =
      email_service.send_cancellation_email_to_attendee(recipient.email, details)

    organizer_result =
      if notify_organizer? do
        organizer_details = AppointmentBuilder.from_meeting(meeting)

        email_service.send_cancellation_email_to_organizer(
          organizer_details.organizer_email,
          organizer_details
        )
      else
        {:ok, :skipped}
      end

    DeliveryOutcome.from_dual_send(
      "seat cancellation",
      [meeting_id: meeting.id, participant_id: participant.id],
      organizer_result,
      attendee_result
    )
  end

  defp parse_old_event(%{
         "old_uid" => uid,
         "old_ical_sequence" => sequence,
         "old_start_time" => start_iso,
         "old_end_time" => end_iso
       })
       when is_binary(uid) and is_integer(sequence) do
    with {:ok, start_time, _offset} <- DateTime.from_iso8601(start_iso),
         {:ok, end_time, _offset} <- DateTime.from_iso8601(end_iso) do
      {:ok, %{uid: uid, ical_sequence: sequence, start_time: start_time, end_time: end_time}}
    else
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  defp parse_old_event(_args), do: {:error, :invalid_snapshot}

  # Also re-sends the mover's still-unsent guests: `RescheduleSeat` re-books
  # the seat's guests against the new participant row (fresh, unsent), so
  # without this call they would keep the confirmation they already had for
  # the old slot — now voided — and never learn where the meeting moved to.
  defp send_seat_reschedule_emails(meeting, participant, old_event) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    email_service = Config.email_service_module()

    attendee_result =
      email_service.send_seat_reschedule_to_participant(recipient.email, details, old_event)

    organizer_details = AppointmentBuilder.from_meeting(meeting)

    organizer_result =
      email_service.send_appointment_confirmation_to_organizer(
        organizer_details.organizer_email,
        organizer_details
      )

    send_participant_guest_confirmations(meeting, recipient, details, email_service)

    DeliveryOutcome.from_dual_send(
      "seat reschedule",
      [meeting_id: meeting.id, participant_id: participant.id],
      organizer_result,
      attendee_result
    )
  end

  # Same send loop `MeetingEmails.send_guest_confirmations/4` uses for a
  # solo booking's guests; only the query scoping it to one participant's
  # guests differs, so that loop is shared rather than copied.
  defp send_participant_guest_confirmations(meeting, recipient, details, email_service) do
    recipient.participant_id
    |> GuestQueries.list_unsent_for_participant()
    |> MeetingEmails.send_guest_confirmations(meeting, details, email_service)
  end

  defp meeting_started?(meeting) do
    DateTime.compare(meeting.start_time, DateTime.utc_now()) != :gt
  end

  # Untranslated, ungrammatical at count 1 ("1 participants") if built with
  # plain interpolation — routed through `dngettext/5` like every other
  # pluralised string in the email templates.
  defp participant_count_label(participants) do
    count = length(participants)

    dngettext("emails", "%{count} participant", "%{count} participants", count, count: count)
  end
end
