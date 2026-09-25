defmodule Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails do
  @moduledoc """
  Handles meeting-related email actions: confirmations, cancellations, reminders, and
  reschedule requests.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.GuestEmails

  @spec handle_confirmation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_confirmation_emails(%{"meeting_id" => meeting_id}) do
    with_meeting(meeting_id, "confirmation emails", &send_confirmation_emails/1)
  end

  @spec handle_reminder_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reminder_emails(%{"meeting_id" => meeting_id} = args) do
    with_meeting(meeting_id, "reminder emails", fn meeting ->
      cond do
        # A void slot (cancelled, or an organizer reschedule request pending)
        # means the original time is no longer valid — reminding anyone of it
        # would contradict the cancellation/reschedule-request email. Pending
        # reminder jobs are deleted when the slot is voided; this guards any
        # job already in flight at that moment.
        MeetingState.slot_void?(meeting) ->
          Logger.info("Skipping reminder emails for inactive meeting",
            meeting_id: meeting_id,
            status: meeting.status
          )

          {:discard, "Meeting #{meeting.status}"}

        # A job snoozed past an outage (open mail breaker) can wake up after
        # the meeting has already started — the reminder copy is worded as
        # if the meeting is still ahead ("in 30 minutes"), so sending it late
        # would be actively misleading rather than just unnecessary.
        meeting_started?(meeting) ->
          Logger.info("Skipping reminder emails - meeting already started",
            meeting_id: meeting_id,
            start_time: meeting.start_time
          )

          {:discard, "Meeting already started"}

        true ->
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

  @spec handle_cancellation_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_cancellation_emails(%{"meeting_id" => meeting_id}, job_id) do
    with_meeting(meeting_id, "cancellation emails", fn meeting ->
      if meeting.status == "cancelled" do
        send_cancellation_emails_for_meeting(meeting, job_id)
      else
        Logger.info("Skipping cancellation emails - meeting is not cancelled",
          meeting_id: meeting_id,
          status: meeting.status
        )

        {:discard, "Meeting not cancelled"}
      end
    end)
  end

  @doc """
  Fetches the meeting and runs `fun` with it, or discards the job with a
  consistent log line when the meeting no longer exists. `action` names the
  email action for the warning (e.g. "confirmation emails").

  Public so `GroupMeetingEmails`'s per-seat handlers and
  `BookingApprovalEmails` share this instead of carrying their own copy — the
  meeting-lookup contract is identical for all of them, only what runs on
  success differs.
  """
  @spec with_meeting(term(), String.t(), (MeetingSchema.t() -> term())) :: term()
  def with_meeting(meeting_id, action, fun) do
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

  # Unlike confirmations and reminders, a cancellation has no per-recipient
  # sent flag on the meeting, so what stops a rescued job re-sending it is a
  # claim on the job itself (`DeliveryClaims`): one for the organiser and
  # attendee pair, which the email service sends in one call, and one for each
  # guest, so a rescue part-way through the guests still tells the rest. A
  # retry after both participant emails failed releases the first claim and
  # sends them again, as before. On a group meeting the first claim covers the
  # per-seat fan-out instead, which is itself safe to repeat (see
  # `GroupMeetingEmails`).
  defp send_cancellation_emails_for_meeting(meeting, job_id) do
    appointment_details = AppointmentBuilder.from_meeting(meeting)

    result =
      DeliveryClaims.once(job_id, "cancellation:participants", fn ->
        send_participant_cancellations(meeting, appointment_details)
      end)

    # Guests are told whenever at least one participant email went out, even
    # on a partial failure that is discarded rather than retried, so they are
    # told now or never.
    if result == :ok or match?({:discard, _reason}, result) do
      GuestNotifications.notify_cancelled(
        meeting,
        appointment_details,
        &DeliveryClaims.once(job_id, &1, &2)
      )
    end

    result
  end

  defp send_participant_cancellations(meeting, appointment_details) do
    Logger.info("Sending cancellation emails", meeting_id: meeting.id, uid: meeting.uid)

    if Meetings.group?(meeting) do
      # `group?/1` is capacity-based, not "has live participants": a meeting
      # emptied by every participant leaving is still a group meeting, so it
      # must fall through to `send_solo_cancellation_emails/2`'s dedicated
      # emptied-group clause below rather than dispatching a fan-out over an
      # empty list.
      case Enum.filter(Meetings.recipients(meeting), &(&1.kind == :participant)) do
        [] -> send_solo_cancellation_emails(meeting, appointment_details)
        participants -> GroupMeetingEmails.send_group_cancellation_emails(meeting, participants)
      end
    else
      send_solo_cancellation_emails(meeting, appointment_details)
    end
  end

  defp send_solo_cancellation_emails(%{attendee_email: email}, details)
       when email in [nil, ""] do
    # An emptied group meeting being cancelled: every participant already
    # received their seat-cancellation email when they left; only the
    # organiser needs the meeting-level cancellation.
    case Config.email_service_module().send_cancellation_email_to_organizer(
           details.organizer_email,
           details
         ) do
      {:ok, _organizer} -> :ok
      {:error, reason} -> {:error, "Failed to send cancellation email: #{inspect(reason)}"}
    end
  end

  defp send_solo_cancellation_emails(meeting, appointment_details) do
    {organizer_result, attendee_result} =
      Config.email_service_module().send_cancellation_emails(appointment_details)

    DeliveryOutcome.from_dual_send(
      "cancellation",
      [meeting_id: meeting.id],
      organizer_result,
      attendee_result
    )
  end

  defp send_confirmation_emails(meeting) do
    if meeting.organizer_email_sent && meeting.attendee_email_sent do
      Logger.info("Confirmation emails already sent for meeting",
        meeting_id: meeting.id,
        organizer_sent: meeting.organizer_email_sent,
        attendee_sent: meeting.attendee_email_sent
      )

      # The participants' flags say nothing about the guests: each guest is
      # stamped on its own, so a retry that finds both participants already
      # stamped still has to invite whoever the previous attempt missed.
      GuestEmails.invite_missed(meeting)

      :ok
    else
      Logger.info("Sending confirmation emails", meeting_id: meeting.id, uid: meeting.uid)

      appointment_details = AppointmentBuilder.from_meeting(meeting)

      need_organizer? = !meeting.organizer_email_sent
      need_attendee? = !meeting.attendee_email_sent

      # The join link itself is a credential for link-based providers, so only
      # whether there is one is logged; `has_meeting_url` is what the branch
      # below turns on, and `meeting_id` on the line above correlates the two.
      Logger.debug("Appointment details for email",
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

      # Guest confirmations are sent alongside the attendee email, but not
      # gated on it: a retry whose previous attempt stamped the attendee and
      # then failed part-way through the guests must still reach the rest.
      # Each guest is stamped with `confirmation_sent_at` after a successful
      # send, so only unsent guests are ever re-attempted. Failures are logged
      # but never block the organiser/attendee confirmation result.
      meeting.id
      |> GuestQueries.list_unsent_for_meeting()
      |> GuestEmails.send_confirmations(meeting, appointment_details, email_service)

      process_email_results(meeting, organizer_result, attendee_result, :confirmation)
    end
  end

  # Group reminders are dispatched (one per-seat job per live participant,
  # plus the organiser reminder sent inline) rather than sent inline here, so
  # there is no per-recipient success/failure pair to feed
  # `process_email_results/4`. `reminders_sent` is instead marked as soon as
  # dispatch succeeds — actual per-recipient delivery is now Oban's job to
  # retry, not this job's. The live participants' guests are reminded inline,
  # as on a solo meeting, each stamped per offset so a retry skips them.
  defp send_reminder_emails(meeting, reminder_value, reminder_unit) do
    Logger.info("Sending reminder emails", meeting_id: meeting.id, uid: meeting.uid)

    if Meetings.group?(meeting) do
      participants = Enum.filter(Meetings.recipients(meeting), &(&1.kind == :participant))

      case GroupMeetingEmails.send_group_reminder_emails(
             meeting,
             participants,
             reminder_value,
             reminder_unit
           ) do
        :ok ->
          remind_group_guests(meeting, reminder_value, reminder_unit)

          with :ok <-
                 update_email_sent_flags(
                   meeting,
                   {:reminder, reminder_value, reminder_unit},
                   true,
                   true
                 ) do
            Logger.info("Reminder emails dispatched",
              meeting_id: meeting.id,
              reminder_value: reminder_value,
              reminder_unit: reminder_unit,
              participant_count: length(participants)
            )

            :ok
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      send_solo_reminder_emails(meeting, reminder_value, reminder_unit)
    end
  end

  defp remind_group_guests(meeting, reminder_value, reminder_unit) do
    appointment_details =
      AppointmentBuilder.from_meeting(meeting, %{value: reminder_value, unit: reminder_unit})

    GuestEmails.send_reminders(meeting, appointment_details, reminder_value, reminder_unit)
  end

  # Sends only to the recipient(s) not yet recorded as sent for this specific
  # reminder config. A meeting can be re-enqueued after a partial send (e.g.
  # the organizer succeeded and the attendee hit an open circuit breaker);
  # without this, a retry would re-email the recipient who already got it.
  defp send_solo_reminder_emails(meeting, reminder_value, reminder_unit) do
    status = reminder_sent_status(meeting, reminder_value, reminder_unit)
    need_organizer? = !status.organizer
    need_attendee? = !status.attendee

    appointment_details =
      AppointmentBuilder.from_meeting(meeting, %{value: reminder_value, unit: reminder_unit})

    email_service = Config.email_service_module()

    organizer_result =
      if need_organizer? do
        email_service.send_appointment_reminder_to_organizer(
          appointment_details.organizer_email,
          appointment_details
        )
      else
        {:ok, :skipped}
      end

    attendee_result =
      if need_attendee? do
        email_service.send_appointment_reminder_to_attendee(
          appointment_details.attendee_email,
          appointment_details
        )
      else
        {:ok, :skipped}
      end

    # Guests are reminded from inside this function, so they inherit its
    # guards: a reminder for a meeting that has already started, or whose slot
    # was voided, never reaches a guest either. Each guest is stamped for this
    # specific offset, so a retry after a partial send re-emails only the
    # guests it has not reached. Failures are logged but never change the
    # organiser/attendee result.
    GuestEmails.send_reminders(meeting, appointment_details, reminder_value, reminder_unit)

    process_email_results(
      meeting,
      organizer_result,
      attendee_result,
      {:reminder, reminder_value, reminder_unit}
    )
  end

  defp send_reschedule_request_email(meeting) do
    Logger.info("Sending reschedule request email", meeting_id: meeting.id, uid: meeting.uid)

    if Meetings.group?(meeting) do
      participants = Enum.filter(Meetings.recipients(meeting), &(&1.kind == :participant))
      GroupMeetingEmails.send_group_reschedule_requests(meeting, participants)
    else
      send_solo_reschedule_request(meeting)
    end
  end

  # The solo counterpart to `GroupMeetingEmails.send_group_reschedule_requests/2`,
  # kept here (not there) since it is solo-only and this module already owns
  # every other solo-meeting send.
  defp send_solo_reschedule_request(meeting) do
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

  # The per-recipient sent flags are recorded before the error is inspected,
  # not after: a partial send (e.g. organizer succeeds, attendee hits an open
  # circuit breaker) must be persisted even though the overall result is an
  # error the worker will retry. Otherwise a retry re-sends to the recipient
  # who already received it.
  #
  # A recipient permanently rejected by the provider is persisted as settled
  # too, even though nothing was actually delivered: no retry can ever reach
  # a dead address, so leaving its flag false would have the job keep
  # re-attempting that recipient on every retry of the other, still-live one.
  #
  # Confirmation flags are the exception: they are updated inline in
  # send_confirmation_emails/1 as each email succeeds, so
  # update_email_sent_flags/4 no-ops for that type below.
  defp process_email_results(meeting, organizer_result, attendee_result, email_type) do
    organizer_delivered = match?({:ok, _result}, organizer_result)
    attendee_delivered = match?({:ok, _result}, attendee_result)
    organizer_settled = organizer_delivered or terminal_failure?(organizer_result)
    attendee_settled = attendee_delivered or terminal_failure?(attendee_result)

    case update_email_sent_flags(meeting, email_type, organizer_settled, attendee_settled) do
      :ok ->
        case check_email_errors(organizer_result, attendee_result) do
          nil ->
            log_email_results(meeting, email_type, organizer_delivered, attendee_delivered)

            if organizer_delivered && attendee_delivered do
              :ok
            else
              {:error, "Failed to send all emails"}
            end

          error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp terminal_failure?({:error, {:recipient_rejected, _reason}}), do: true
  defp terminal_failure?(_other), do: false

  defp check_email_errors(organizer_result, attendee_result) do
    results = [organizer_result, attendee_result]

    cond do
      match?({:error, :rate_limited}, organizer_result) or
          match?({:error, :rate_limited}, attendee_result) ->
        {:error, :rate_limited}

      reason = DeliveryOutcome.first_actionable(results) ->
        {:error, reason}

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
      case MeetingQueries.upsert_reminder_sent(meeting, %{
             value: reminder_value,
             unit: reminder_unit,
             organizer_sent: organizer_success,
             attendee_sent: attendee_success
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

  defp meeting_started?(meeting) do
    DateTime.compare(meeting.start_time, DateTime.utc_now()) != :gt
  end

  defp reminder_already_sent?(meeting, reminder_value, reminder_unit) do
    status = reminder_sent_status(meeting, reminder_value, reminder_unit)
    status.organizer and status.attendee
  end

  # Per-recipient delivery state for one reminder config. An entry with no
  # matching `(value, unit)` means neither recipient has been sent to yet; an
  # entry written before per-recipient tracking existed (no `organizer_sent`/
  # `attendee_sent` keys) is treated as fully sent, since it predates this
  # tracking and existing behaviour already skipped it entirely.
  defp reminder_sent_status(meeting, reminder_value, reminder_unit) do
    reminder_value = ReminderUtils.parse_reminder_value(reminder_value)
    reminder_unit = ReminderUtils.normalize_reminder_unit(reminder_unit)

    meeting.reminders_sent
    |> List.wrap()
    |> Enum.find(fn reminder ->
      case reminder do
        %{"value" => value, "unit" => unit} -> value == reminder_value and unit == reminder_unit
        %{value: value, unit: unit} -> value == reminder_value and unit == reminder_unit
        _other -> false
      end
    end)
    |> reminder_entry_status()
  end

  defp reminder_entry_status(nil), do: %{organizer: false, attendee: false}

  defp reminder_entry_status(entry) do
    %{
      organizer: reminder_entry_flag(entry, "organizer_sent", :organizer_sent),
      attendee: reminder_entry_flag(entry, "attendee_sent", :attendee_sent)
    }
  end

  defp reminder_entry_flag(entry, string_key, atom_key) do
    case entry do
      %{^string_key => sent} when is_boolean(sent) -> sent
      %{^atom_key => sent} when is_boolean(sent) -> sent
      _other -> true
    end
  end
end
