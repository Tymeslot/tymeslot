defmodule Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails do
  @moduledoc """
  Handles meeting-related email actions: confirmations, cancellations, reminders, and
  reschedule requests.
  """

  require Logger

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Utils.ReminderUtils

  @spec handle_confirmation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_confirmation_emails(%{"meeting_id" => meeting_id}) do
    with_meeting(meeting_id, "confirmation emails", &send_confirmation_emails/1)
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

  defp send_cancellation_emails_for_meeting(meeting) do
    Logger.info("Sending cancellation emails", meeting_id: meeting.id, uid: meeting.uid)

    appointment_details = AppointmentBuilder.from_meeting(meeting)

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
            worker_actionable_reason([organizer_result, attendee_result]) ||
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

    process_email_results(
      meeting,
      organizer_result,
      attendee_result,
      {:reminder, reminder_value, reminder_unit}
    )
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
  defp process_email_results(meeting, organizer_result, attendee_result, email_type) do
    organizer_success = match?({:ok, _result}, organizer_result)
    attendee_success = match?({:ok, _result}, attendee_result)

    case update_email_sent_flags(meeting, email_type, organizer_success, attendee_success) do
      :ok ->
        case check_email_errors(organizer_result, attendee_result) do
          nil ->
            log_email_results(meeting, email_type, organizer_success, attendee_success)

            if organizer_success || attendee_success do
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

  defp check_email_errors(organizer_result, attendee_result) do
    results = [organizer_result, attendee_result]

    cond do
      match?({:error, :rate_limited}, organizer_result) or
          match?({:error, :rate_limited}, attendee_result) ->
        {:error, :rate_limited}

      reason = worker_actionable_reason(results) ->
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

  # The two failures `EmailWorker` must act on differently from an ordinary
  # retry, preserved rather than flattened into a message — the same contract
  # `DeliveryOutcome.from_error/2` gives every other handler.
  #
  # `:circuit_open` is the one that mattered here: the mail breaker stays open
  # for five minutes, and this worker's backoff spends all five attempts inside
  # the first fifteen seconds of that window, so flattening it dropped booking
  # confirmations, reminders and cancellations outright for the duration of any
  # mail outage. The worker snoozes past the window instead, at no cost in
  # attempts.
  defp worker_actionable_reason(results) do
    Enum.find_value(results, fn
      {:error, :circuit_open} -> :circuit_open
      {:error, {:recipient_rejected, _reason} = rejection} -> rejection
      _other -> nil
    end)
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
