defmodule Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails do
  @moduledoc """
  Handles meeting-related email actions: confirmations, cancellations, reminders, and
  reschedule requests.
  """

  require Logger

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails

  @spec handle_confirmation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_confirmation_emails(%{"meeting_id" => meeting_id}) do
    with_meeting(meeting_id, "confirmation emails", &send_confirmation_emails/1)
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

  @spec handle_reminder_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reminder_emails(%{"meeting_id" => meeting_id} = args) do
    with_meeting(meeting_id, "reminder emails", fn meeting ->
      # A void slot (cancelled, or an organizer reschedule request pending)
      # means the original time is no longer valid — reminding anyone of it
      # would contradict the cancellation/reschedule-request email. Pending
      # reminder jobs are deleted when the slot is voided; this guards any
      # job already in flight at that moment.
      if MeetingState.slot_void?(meeting) do
        Logger.info("Skipping reminder emails for inactive meeting",
          meeting_id: meeting_id,
          status: meeting.status
        )

        {:discard, "Meeting #{meeting.status}"}
      else
        reminder_value = Map.get(args, "reminder_value", 30)
        reminder_unit = Map.get(args, "reminder_unit", "minutes")

        if reminder_already_sent?(meeting, reminder_value, reminder_unit) do
          Logger.info("Skipping reminder emails - already sent",
            meeting_id: meeting_id
          )

          :ok
        else
          send_reminder_emails(meeting, reminder_value, reminder_unit)
        end
      end
    end)
  end

  @spec handle_reschedule_request(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_request(%{"meeting_id" => meeting_id}) do
    with_meeting(meeting_id, "reschedule request", fn meeting ->
      if meeting.status == "cancelled" do
        Logger.info("Skipping reschedule request for cancelled meeting",
          meeting_id: meeting_id
        )

        {:discard, "Meeting cancelled"}
      else
        send_reschedule_request_email(meeting)
      end
    end)
  end

  @spec handle_cancellation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_cancellation_emails(%{"meeting_id" => meeting_id}) do
    with_meeting(meeting_id, "cancellation emails", fn meeting ->
      if meeting.status == "cancelled" do
        send_cancellation_emails_for_meeting(meeting)
      else
        Logger.info("Skipping cancellation emails - meeting is not cancelled",
          meeting_id: meeting_id,
          status: meeting.status
        )

        {:discard, "Meeting not cancelled"}
      end
    end)
  end

  # Fetches the meeting and runs `fun` with it, or discards the job with a
  # consistent log line when the meeting no longer exists. `action` names the
  # email action for the warning (e.g. "confirmation emails").
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

  defp send_cancellation_emails_for_meeting(meeting) do
    Logger.info("Sending cancellation emails", meeting_id: meeting.id, uid: meeting.uid)

    case Enum.filter(Meetings.recipients(meeting), &(&1.kind == :participant)) do
      [] -> send_solo_cancellation_emails(meeting)
      participants -> GroupMeetingEmails.send_group_cancellation_emails(meeting, participants)
    end
  end

  defp send_solo_cancellation_emails(%{attendee_email: email} = meeting)
       when email in [nil, ""] do
    # An emptied group meeting being cancelled: every participant already
    # received their seat-cancellation email when they left; only the
    # organiser needs the meeting-level cancellation.
    details = AppointmentBuilder.from_meeting(meeting)

    case Config.email_service_module().send_cancellation_email_to_organizer(
           details.organizer_email,
           details
         ) do
      {:ok, _organizer} -> :ok
      {:error, reason} -> {:error, "Failed to send cancellation email: #{inspect(reason)}"}
    end
  end

  defp send_solo_cancellation_emails(meeting) do
    appointment_details = AppointmentBuilder.from_meeting(meeting)

    {organizer_result, attendee_result} =
      Config.email_service_module().send_cancellation_emails(appointment_details)

    summarize_dual_send(
      "cancellation",
      [meeting_id: meeting.id],
      organizer_result,
      attendee_result
    )
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
    seat_meeting = Meetings.meeting_as_seen_by(meeting, recipient)
    details = AppointmentBuilder.from_meeting(seat_meeting)
    email_service = Config.email_service_module()

    organizer_result =
      email_service.send_appointment_confirmation_to_organizer(details.organizer_email, details)

    attendee_result =
      email_service.send_appointment_confirmation_to_attendee(recipient.email, details)

    send_participant_guest_confirmations(meeting, recipient, details, email_service)

    summarize_dual_send(
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

    details =
      meeting
      |> Meetings.meeting_as_seen_by(recipient)
      |> AppointmentBuilder.from_meeting()

    email_service = Config.email_service_module()

    attendee_result =
      email_service.send_cancellation_email_to_attendee(recipient.email, details)

    organizer_result =
      if notify_organizer? do
        email_service.send_cancellation_email_to_organizer(details.organizer_email, details)
      else
        {:ok, :skipped}
      end

    summarize_dual_send(
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

    details =
      meeting
      |> Meetings.meeting_as_seen_by(recipient)
      |> AppointmentBuilder.from_meeting()

    email_service = Config.email_service_module()

    attendee_result =
      email_service.send_seat_reschedule_to_participant(recipient.email, details, old_event)

    organizer_result =
      email_service.send_appointment_confirmation_to_organizer(details.organizer_email, details)

    summarize_dual_send(
      "seat reschedule",
      [meeting_id: meeting.id, participant_id: participant.id],
      organizer_result,
      attendee_result
    )
  end

  # :ok once both sides succeed, {:discard, _} on a partial send so a retry
  # can't duplicate the email that already went out, {:error, _} if neither did.
  defp summarize_dual_send(label, metadata, organizer_result, attendee_result) do
    case {organizer_result, attendee_result} do
      {{:ok, _organizer}, {:ok, _attendee}} ->
        :ok

      {organizer_result, attendee_result} ->
        Logger.warning(
          "Some emails may have failed",
          metadata ++
            [
              label: label,
              organizer_result: inspect(organizer_result),
              attendee_result: inspect(attendee_result)
            ]
        )

        if match?({:ok, _}, organizer_result) or match?({:ok, _}, attendee_result) do
          {:discard, "Partial #{label} failure: retry would duplicate"}
        else
          {:error, "Failed to send #{label} emails"}
        end
    end
  end

  # Same mechanics as send_guest_confirmations/3, scoped to one participant's
  # guests. Guests are stamped after a successful send so Oban retries only
  # re-attempt unsent guests.
  defp send_participant_guest_confirmations(meeting, recipient, details, email_service) do
    recipient.participant_id
    |> GuestQueries.list_unsent_for_participant()
    |> Enum.each(fn guest ->
      guest_details = guest_appointment_details(details, guest)

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

  defp send_confirmation_emails(meeting) do
    if meeting.organizer_email_sent && meeting.attendee_email_sent do
      Logger.info("Confirmation emails already sent for meeting",
        meeting_id: meeting.id,
        organizer_sent: meeting.organizer_email_sent,
        attendee_sent: meeting.attendee_email_sent
      )

      :ok
    else
      Logger.info("Sending confirmation emails", meeting_id: meeting.id, uid: meeting.uid)

      appointment_details = AppointmentBuilder.from_meeting(meeting)

      need_organizer? = !meeting.organizer_email_sent
      need_attendee? = !meeting.attendee_email_sent

      # Debug logging
      Logger.debug("Appointment details for email",
        meeting_url: appointment_details.meeting_url,
        has_meeting_url: !is_nil(appointment_details.meeting_url),
        need_organizer: need_organizer?,
        need_attendee: need_attendee?
      )

      email_service = Config.email_service_module()

      organizer_result =
        if need_organizer? do
          with {:ok, _result} <-
                 email_service.send_appointment_confirmation_to_organizer(
                   appointment_details.organizer_email,
                   appointment_details
                 ),
               {:ok, _meeting} <- MeetingQueries.mark_email_sent(meeting, :organizer) do
            {:ok, :sent}
          else
            {:error, reason} ->
              Logger.error("Organizer confirmation step failed",
                meeting_id: meeting.id,
                error: inspect(reason)
              )

              {:error, reason}
          end
        else
          {:ok, :skipped}
        end

      attendee_result =
        if need_attendee? do
          with {:ok, _result} <-
                 email_service.send_appointment_confirmation_to_attendee(
                   appointment_details.attendee_email,
                   appointment_details
                 ),
               {:ok, _meeting} <- MeetingQueries.mark_email_sent(meeting, :attendee) do
            {:ok, :sent}
          else
            {:error, reason} ->
              Logger.error("Attendee confirmation step failed",
                meeting_id: meeting.id,
                error: inspect(reason)
              )

              {:error, reason}
          end
        else
          {:ok, :skipped}
        end

      # Guest confirmations are sent alongside the attendee email. Each guest is
      # stamped with `confirmation_sent_at` after a successful send, so Oban
      # retries only re-attempt unsent guests. Failures are logged but never
      # block the organiser/attendee confirmation result.
      if need_attendee?, do: send_guest_confirmations(meeting, appointment_details, email_service)

      process_email_results(meeting, organizer_result, attendee_result, :confirmation)
    end
  end

  defp send_guest_confirmations(meeting, appointment_details, email_service) do
    meeting.id
    |> GuestQueries.list_unsent_for_meeting()
    |> Enum.each(fn guest ->
      details = guest_appointment_details(appointment_details, guest)

      case email_service.send_guest_confirmation(guest.email, details) do
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

  defp guest_appointment_details(appointment_details, guest) do
    urls = Policy.guest_rsvp_urls(guest.rsvp_token)

    appointment_details
    |> Map.put(:guest_name, guest.name || guest.email)
    |> Map.put(:guest_accept_url, urls.accept_url)
    |> Map.put(:guest_decline_url, urls.decline_url)
  end

  defp send_reminder_emails(meeting, reminder_value, reminder_unit) do
    Logger.info("Sending reminder emails", meeting_id: meeting.id, uid: meeting.uid)

    case Enum.filter(Meetings.recipients(meeting), &(&1.kind == :participant)) do
      [] ->
        send_solo_reminder_emails(meeting, reminder_value, reminder_unit)

      participants ->
        {organizer_result, attendee_result} =
          GroupMeetingEmails.send_group_reminder_emails(
            meeting,
            participants,
            reminder_value,
            reminder_unit
          )

        process_email_results(
          meeting,
          organizer_result,
          attendee_result,
          {:reminder, reminder_value, reminder_unit}
        )
    end
  end

  defp send_solo_reminder_emails(meeting, reminder_value, reminder_unit) do
    appointment_details =
      AppointmentBuilder.from_meeting(meeting, %{value: reminder_value, unit: reminder_unit})

    time_until = appointment_details.time_until

    case Config.email_service_module().send_appointment_reminders(appointment_details, time_until) do
      {organizer_result, attendee_result} ->
        process_email_results(
          meeting,
          organizer_result,
          attendee_result,
          {:reminder, reminder_value, reminder_unit}
        )
    end
  end

  defp send_reschedule_request_email(meeting) do
    Logger.info("Sending reschedule request email", meeting_id: meeting.id, uid: meeting.uid)

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

  # Confirmation flags are updated inline in send_confirmation_emails/1 as
  # each email succeeds, so update_email_sent_flags/4 no-ops for it below.
  defp process_email_results(meeting, organizer_result, attendee_result, email_type) do
    organizer_success = match?({:ok, _result}, organizer_result)
    attendee_success = match?({:ok, _result}, attendee_result)

    with nil <- check_email_errors(organizer_result, attendee_result),
         :ok <- update_email_sent_flags(meeting, email_type, organizer_success, attendee_success) do
      log_email_results(meeting, email_type, organizer_success, attendee_success)

      if email_success?(email_type, organizer_success, attendee_success) do
        :ok
      else
        {:error, "Failed to send all emails"}
      end
    end
  end

  defp email_success?(:confirmation, organizer_success, attendee_success),
    do: organizer_success && attendee_success

  defp email_success?(_email_type, organizer_success, attendee_success),
    do: organizer_success || attendee_success

  defp check_email_errors(organizer_result, attendee_result) do
    cond do
      match?({:error, :rate_limited}, organizer_result) or
          match?({:error, :rate_limited}, attendee_result) ->
        {:error, :rate_limited}

      match?({:error, :invalid_email}, organizer_result) or
          match?({:error, :invalid_email}, attendee_result) ->
        {:error, :invalid_email}

      true ->
        case {organizer_result, attendee_result} do
          {{:error, reason}, {:error, reason}} when is_binary(reason) ->
            {:error, reason}

          _other ->
            nil
        end
    end
  end

  defp update_email_sent_flags(_meeting, :confirmation, _organizer_success, _attendee_success),
    do: :ok

  defp update_email_sent_flags(
         meeting,
         {:reminder, reminder_value, reminder_unit},
         organizer_success,
         attendee_success
       ) do
    if organizer_success || attendee_success do
      case MeetingQueries.append_reminder_sent(meeting, %{
             value: reminder_value,
             unit: reminder_unit
           }) do
        {:ok, _updated_meeting} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to track reminder as sent",
            meeting_id: meeting.id,
            reminder_value: reminder_value,
            reminder_unit: reminder_unit,
            error: inspect(reason)
          )

          {:error, "Failed to track reminder: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp log_email_results(meeting, {:reminder, val, unit}, organizer_success, attendee_success) do
    metadata = [
      reminder_value: val,
      reminder_unit: unit,
      meeting_id: meeting.id,
      organizer_sent: organizer_success,
      attendee_sent: attendee_success
    ]

    if organizer_success != attendee_success do
      Logger.warning(
        "Partial reminder delivery — one recipient did not receive the email",
        metadata
      )
    else
      Logger.info("Reminder emails sent", metadata)
    end
  end

  defp log_email_results(meeting, email_type, organizer_success, attendee_success) do
    Logger.info("Emails sent",
      email_type: email_type,
      meeting_id: meeting.id,
      organizer_sent: organizer_success,
      attendee_sent: attendee_success
    )
  end

  defp reminder_already_sent?(meeting, reminder_value, reminder_unit) do
    reminder_value = ReminderUtils.parse_reminder_value(reminder_value)
    reminder_unit = ReminderUtils.normalize_reminder_unit(reminder_unit)

    meeting.reminders_sent
    |> List.wrap()
    |> Enum.any?(fn reminder ->
      case reminder do
        %{"value" => value, "unit" => unit} -> value == reminder_value and unit == reminder_unit
        %{value: value, unit: unit} -> value == reminder_value and unit == reminder_unit
        _other -> false
      end
    end)
  end
end
