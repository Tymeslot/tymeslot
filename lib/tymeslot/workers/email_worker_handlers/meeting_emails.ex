defmodule Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails do
  @moduledoc """
  Handles meeting-related email actions: confirmations, cancellations, reminders, and
  reschedule requests.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Utils.ReminderUtils

  @spec handle_confirmation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_confirmation_emails(%{"meeting_id" => meeting_id}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        send_confirmation_emails(meeting)

      {:error, :not_found} ->
        Logger.warning("Attempted to send confirmation emails for non-existent meeting",
          meeting_id: meeting_id
        )

        {:discard, "Meeting not found"}
    end
  end

  @spec handle_reminder_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reminder_emails(%{"meeting_id" => meeting_id} = args) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        if meeting.status == "cancelled" do
          Logger.info("Skipping reminder emails for cancelled meeting",
            meeting_id: meeting_id
          )

          {:discard, "Meeting cancelled"}
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

      {:error, :not_found} ->
        Logger.warning("Attempted to send reminder emails for non-existent meeting",
          meeting_id: meeting_id
        )

        {:discard, "Meeting not found"}
    end
  end

  @spec handle_reschedule_request(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_request(%{"meeting_id" => meeting_id}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        if meeting.status == "cancelled" do
          Logger.info("Skipping reschedule request for cancelled meeting",
            meeting_id: meeting_id
          )

          {:discard, "Meeting cancelled"}
        else
          send_reschedule_request_email(meeting)
        end

      {:error, :not_found} ->
        Logger.warning("Attempted to send reschedule request for non-existent meeting",
          meeting_id: meeting_id
        )

        {:discard, "Meeting not found"}
    end
  end

  @spec handle_cancellation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_cancellation_emails(%{"meeting_id" => meeting_id}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        if meeting.status == "cancelled" do
          send_cancellation_emails_for_meeting(meeting)
        else
          Logger.info("Skipping cancellation emails - meeting is not cancelled",
            meeting_id: meeting_id,
            status: meeting.status
          )

          {:discard, "Meeting not cancelled"}
        end

      {:error, :not_found} ->
        Logger.warning("Attempted to send cancellation emails for non-existent meeting",
          meeting_id: meeting_id
        )

        {:discard, "Meeting not found"}
    end
  end

  defp send_cancellation_emails_for_meeting(meeting) do
    Logger.info("Sending cancellation emails", meeting_id: meeting.id, uid: meeting.uid)

    appointment_details = AppointmentBuilder.from_meeting(meeting)

    case email_service_module().send_cancellation_emails(appointment_details) do
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
          {:error, "Failed to send cancellation emails"}
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

      email_service = email_service_module()

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

      process_email_results(meeting, organizer_result, attendee_result, :confirmation)
    end
  end

  defp send_reminder_emails(meeting, reminder_value, reminder_unit) do
    Logger.info("Sending reminder emails", meeting_id: meeting.id, uid: meeting.uid)

    appointment_details =
      AppointmentBuilder.from_meeting(meeting, %{value: reminder_value, unit: reminder_unit})

    time_until = appointment_details.time_until

    case email_service_module().send_appointment_reminders(appointment_details, time_until) do
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

    case email_service_module().send_reschedule_request(meeting) do
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

  defp process_email_results(meeting, organizer_result, attendee_result, email_type) do
    organizer_success = match?({:ok, _result}, organizer_result)
    attendee_success = match?({:ok, _result}, attendee_result)

    case check_email_errors(organizer_result, attendee_result) do
      nil ->
        case update_email_sent_flags(meeting, email_type, organizer_success, attendee_success) do
          :ok ->
            log_email_results(meeting, email_type, organizer_success, attendee_success)

            if organizer_success || attendee_success do
              :ok
            else
              {:error, "Failed to send all emails"}
            end

          {:error, _reason} = error ->
            error
        end

      error ->
        error
    end
  end

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

  defp email_service_module do
    Application.get_env(:tymeslot, :email_service_module) ||
      Application.get_env(:tymeslot, :email_service) ||
      Tymeslot.Emails.EmailService
  end
end
