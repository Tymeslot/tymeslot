defmodule Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails do
  @moduledoc """
  Handles meeting-related email actions: confirmations, cancellations, reminders, and
  reschedule requests.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome

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

  @doc false
  # Fetches the meeting and runs `fun` with it, or discards the job with a
  # consistent log line when the meeting no longer exists. `action` names the
  # email action for the warning (e.g. "confirmation emails"). Public so
  # `BookingApprovalEmails` can share it rather than duplicating it.
  @spec with_meeting(String.t(), String.t(), (Tymeslot.Meetings.MeetingSchema.t() -> term())) ::
          term()
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
  # attendee pair, which the email service sends in one call, and one for the
  # guests. A retry after both participant emails failed releases the first
  # claim and sends them again, as before.
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
      DeliveryClaims.once(job_id, "cancellation:guests", fn ->
        GuestNotifications.notify_cancelled(meeting, appointment_details)
      end)
    end

    result
  end

  defp send_participant_cancellations(meeting, appointment_details) do
    Logger.info("Sending cancellation emails", meeting_id: meeting.id, uid: meeting.uid)

    case Config.email_service_module().send_cancellation_emails(appointment_details) do
      {{:ok, _organizer}, {:ok, _attendee}} ->
        Logger.info("Cancellation emails sent successfully", meeting_id: meeting.id)
        :ok

      {organizer_result, attendee_result} ->
        Logger.warning("Some cancellation emails may have failed",
          meeting_id: meeting.id,
          organizer_result: inspect(organizer_result),
          attendee_result: inspect(attendee_result)
        )

        if match?({:ok, _}, organizer_result) or match?({:ok, _}, attendee_result) do
          {:discard,
           "Partial cancellation email failure: one email succeeded, retry would duplicate"}
        else
          reason =
            DeliveryOutcome.first_actionable([organizer_result, attendee_result]) ||
              "Failed to send cancellation emails"

          {:error, reason}
        end
    end
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
      invite_missed_guests(meeting)

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
      send_guest_confirmations(meeting, appointment_details, email_service)

      process_email_results(meeting, organizer_result, attendee_result, :confirmation)
    end
  end

  # Builds the payload only when there is somebody to send to, so the
  # already-sent path stays one cheap query.
  defp invite_missed_guests(meeting) do
    case GuestQueries.list_unsent_for_meeting(meeting.id) do
      [] ->
        :ok

      _unsent ->
        send_guest_confirmations(
          meeting,
          AppointmentBuilder.from_meeting(meeting),
          Config.email_service_module()
        )
    end
  end

  defp send_guest_confirmations(meeting, appointment_details, email_service) do
    meeting.id
    |> GuestQueries.list_unsent_for_meeting()
    |> Enum.each(fn guest ->
      details = GuestNotifications.guest_details(appointment_details, guest)

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

  # Sends only to the recipient(s) not yet recorded as sent for this specific
  # reminder config. A meeting can be re-enqueued after a partial send (e.g.
  # the organizer succeeded and the attendee hit an open circuit breaker);
  # without this, a retry would re-email the recipient who already got it.
  defp send_reminder_emails(meeting, reminder_value, reminder_unit) do
    Logger.info("Sending reminder emails", meeting_id: meeting.id, uid: meeting.uid)

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
    send_guest_reminders(meeting, appointment_details, reminder_value, reminder_unit)

    process_email_results(
      meeting,
      organizer_result,
      attendee_result,
      {:reminder, reminder_value, reminder_unit}
    )
  end

  defp send_guest_reminders(meeting, appointment_details, reminder_value, reminder_unit) do
    value = ReminderUtils.parse_reminder_value(reminder_value)
    unit = ReminderUtils.normalize_reminder_unit(reminder_unit)
    email_service = Config.email_service_module()

    meeting.id
    |> GuestQueries.list_for_reminder(value, unit)
    |> Enum.each(fn guest ->
      details = GuestNotifications.guest_details(appointment_details, guest)

      case email_service.send_guest_reminder(guest.email, details) do
        {:ok, _result} ->
          GuestQueries.mark_reminder_sent(guest, value, unit)

        other ->
          Logger.error("Guest reminder email failed",
            meeting_id: meeting.id,
            guest_id: guest.id,
            result: inspect(other)
          )
      end
    end)
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

  # Confirmation flags are already updated inline in send_confirmation_emails/1
  # immediately after each email succeeds, so no flag tracking step is needed.
  defp process_email_results(meeting, organizer_result, attendee_result, :confirmation) do
    organizer_success = match?({:ok, _result}, organizer_result)
    attendee_success = match?({:ok, _result}, attendee_result)

    case check_email_errors(organizer_result, attendee_result) do
      nil ->
        log_email_results(meeting, :confirmation, organizer_success, attendee_success)

        if organizer_success && attendee_success,
          do: :ok,
          else: {:error, "Failed to send all emails"}

      error ->
        error
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
    if organizer_success != attendee_success do
      Logger.warning("Partial reminder delivery — one recipient did not receive the email",
        reminder_value: val,
        reminder_unit: unit,
        meeting_id: meeting.id,
        organizer_sent: organizer_success,
        attendee_sent: attendee_success
      )
    else
      Logger.info("Reminder emails sent",
        reminder_value: val,
        reminder_unit: unit,
        meeting_id: meeting.id,
        organizer_sent: organizer_success,
        attendee_sent: attendee_success
      )
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
