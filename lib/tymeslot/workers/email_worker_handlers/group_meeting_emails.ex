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
  (`process_email_results/4`).
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome

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
  """
  @spec handle_seat_reminder_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_reminder_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id,
        "reminder_value" => reminder_value,
        "reminder_unit" => reminder_unit
      }) do
    with_meeting_and_participant(
      meeting_id,
      participant_id,
      "seat reminder email",
      fn meeting, participant ->
        send_seat_reminder_email(meeting, participant, reminder_value, reminder_unit)
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
          :ok | {:error, String.t()}
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
        |> Map.put(:attendee_name, "#{length(participants)} participants")

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
  @spec send_seat_meeting_cancellation_email(MeetingSchema.t(), ParticipantSchema.t()) ::
          :ok | {:error, String.t()}
  def send_seat_meeting_cancellation_email(meeting, participant) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)

    result =
      Config.email_service_module().send_cancellation_email_to_attendee(recipient.email, details)

    send_seat_result(result, "cancellation", meeting.id, participant.id)
  end

  @doc """
  Dispatches one reminder job per live participant plus one organiser
  reminder sent inline.
  """
  @spec send_group_reminder_emails(MeetingSchema.t(), [Recipient.t()], pos_integer(), String.t()) ::
          :ok | {:error, String.t()}
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
        |> Map.put(:attendee_name, "#{length(participants)} participants")

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
          ParticipantSchema.t(),
          pos_integer(),
          String.t()
        ) ::
          :ok | {:error, String.t()}
  def send_seat_reminder_email(meeting, participant, reminder_value, reminder_unit) do
    recipient = Recipient.from_participant(participant)
    reminder = %{value: reminder_value, unit: reminder_unit}
    details = AppointmentBuilder.from_meeting(meeting, recipient, reminder)

    result =
      Config.email_service_module().send_appointment_reminder_to_attendee(
        recipient.email,
        details
      )

    send_seat_result(result, "reminder", meeting.id, participant.id)
  end

  @doc """
  Dispatches one reschedule-request job per live participant. The host
  asking to move a group meeting voids the slot for everybody on it, so
  everybody has to hear about it; there is no organiser email in this flow,
  since the host is the one making the request.
  """
  @spec send_group_reschedule_requests(MeetingSchema.t(), [Recipient.t()]) ::
          :ok | {:error, String.t()}
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
  @spec send_seat_reschedule_request(MeetingSchema.t(), ParticipantSchema.t()) ::
          :ok | {:error, String.t()}
  def send_seat_reschedule_request(meeting, participant) do
    recipient = Recipient.from_participant(participant)

    meeting
    |> Meetings.meeting_as_seen_by(recipient)
    |> Config.email_service_module().send_reschedule_request()
    |> send_seat_result("reschedule request", meeting.id, participant.id)
  end

  @doc """
  The solo counterpart: one reschedule request to the meeting's own attendee.

  Lives beside the group version so the caller has both halves of the same
  decision in one place.
  """
  @spec send_solo_reschedule_request(MeetingSchema.t()) :: :ok | {:error, term()}
  def send_solo_reschedule_request(meeting) do
    case Config.email_service_module().send_reschedule_request(meeting) do
      {:ok, _result} ->
        Logger.info("Reschedule request email sent successfully",
          meeting_id: meeting.id,
          to: meeting.attendee_email
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to send reschedule request email",
          meeting_id: meeting.id,
          to: meeting.attendee_email,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Schedules `schedule_fun` for every participant. Each per-seat job is
  # uniqued on `(action, meeting_id, participant_id)`, so re-running this on
  # retry after a downstream (e.g. organiser-email) failure cannot duplicate
  # a job that was already enqueued.
  defp dispatch_seat_jobs(participants, schedule_fun) do
    results = Enum.map(participants, schedule_fun)

    if Enum.all?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, "Failed to schedule one or more seat email jobs"}
    end
  end

  defp send_organizer_email({:ok, _result}, _label), do: :ok

  defp send_organizer_email({:error, reason}, label),
    do: {:error, "Failed to send organiser #{label} email: #{inspect(reason)}"}

  defp send_seat_result({:ok, _result}, _label, _meeting_id, _participant_id), do: :ok

  defp send_seat_result({:error, reason}, label, meeting_id, participant_id) do
    Logger.error("Failed to send seat email",
      label: label,
      meeting_id: meeting_id,
      participant_id: participant_id,
      error: inspect(reason)
    )

    {:error, "Failed to send seat #{label} email: #{inspect(reason)}"}
  end

  # Fetches the meeting and its participant and runs `fun` with both, or
  # discards the job with a consistent log line when either no longer
  # exists. `action` names the email action for the warning (e.g. "seat
  # reminder email"). Mirrors `MeetingEmails.with_meeting/3`, scoped to the
  # per-seat jobs dispatched from this module.
  defp with_meeting_and_participant(meeting_id, participant_id, action, fun) do
    with_meeting(meeting_id, action, fn meeting ->
      case ParticipantQueries.get(participant_id) do
        {:ok, participant} -> fun.(meeting, participant)
        {:error, :not_found} -> {:discard, "Participant not found"}
      end
    end)
  end

  # The meeting-only half of the same contract, for the seat handlers that
  # resolve their participant themselves (through `Meetings.recipients/1`, or
  # by id because the seat is already cancelled).
  defp with_meeting(meeting_id, action, fun) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        fun.(meeting)

      {:error, :not_found} ->
        Logger.warning("Attempted to send email for non-existent meeting",
          email_action: action,
          meeting_id: meeting_id
        )

        {:discard, "Meeting not found"}
    end
  end

  @spec handle_seat_confirmation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_confirmation_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id
      }) do
    with_meeting(meeting_id, "seat confirmation emails", fn meeting ->
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
    with_meeting(meeting_id, "seat cancellation emails", fn meeting ->
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
    with_meeting(meeting_id, "seat reschedule emails", fn meeting ->
      with {:ok, participant} <- ParticipantQueries.get(participant_id),
           {:ok, old_event} <- parse_old_event(args) do
        send_seat_reschedule_emails(meeting, participant, old_event)
      else
        {:error, :not_found} -> {:discard, "Participant not found"}
        {:error, :invalid_snapshot} -> {:discard, "Invalid old-event snapshot"}
      end
    end)
  end

  defp find_live_recipient(meeting, participant_id) do
    meeting
    |> Meetings.recipients()
    |> Enum.find(&(&1.participant_id == participant_id))
  end

  # One participant's confirmation plus the organiser's per-seat notification.
  # Idempotency is job-level (no sent flags on participants): a full failure
  # retries, a partial failure discards so the retry cannot duplicate the
  # email that already went out — mirroring the cancellation-email semantics.
  defp send_seat_confirmation_emails(meeting, recipient) do
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    email_service = Config.email_service_module()

    organizer_result =
      email_service.send_appointment_confirmation_to_organizer(details.organizer_email, details)

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
        email_service.send_cancellation_email_to_organizer(details.organizer_email, details)
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

  defp send_seat_reschedule_emails(meeting, participant, old_event) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    email_service = Config.email_service_module()

    attendee_result =
      email_service.send_seat_reschedule_to_participant(recipient.email, details, old_event)

    organizer_result =
      email_service.send_appointment_confirmation_to_organizer(details.organizer_email, details)

    DeliveryOutcome.from_dual_send(
      "seat reschedule",
      [meeting_id: meeting.id, participant_id: participant.id],
      organizer_result,
      attendee_result
    )
  end

  # Same mechanics as `MeetingEmails` uses for a solo booking, scoped to one
  # participant's
  # guests. Guests are stamped after a successful send so Oban retries only
  # re-attempt unsent guests.
  defp send_participant_guest_confirmations(meeting, recipient, details, email_service) do
    recipient.participant_id
    |> GuestQueries.list_unsent_for_participant()
    |> Enum.each(fn guest ->
      guest_details = AppointmentBuilder.put_guest(details, guest)

      case email_service.send_guest_confirmation(guest.email, guest_details) do
        {:ok, _result} ->
          GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))

        other ->
          Logger.error("Guest confirmation email failed",
            meeting_id: meeting.id,
            guest_email: guest.email,
            result: inspect(other)
          )
      end
    end)
  end
end
