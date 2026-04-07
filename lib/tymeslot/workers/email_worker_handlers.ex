defmodule Tymeslot.Workers.EmailWorkerHandlers do
  @moduledoc """
  Internal handlers for EmailWorker actions.
  """

  require Logger

  alias Tymeslot.DatabaseQueries.{
    CalendarIntegrationQueries,
    IntegrationHealthStateQueries,
    MeetingQueries,
    UserQueries,
    VideoIntegrationQueries
  }

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Utils.ReminderUtils

  @doc """
  Executes the specified email action with the given arguments.

  This is the primary entry point for the EmailWorker to process various types of
  email jobs, including confirmations, reminders, and authentication emails.

  Returns `:ok` on success, `{:error, reason}` for retriable failures,
  `{:discard, reason}` for fatal errors that shouldn't be retried,
  or `{:snooze, seconds}` if the job should be delayed.
  """
  @spec execute_email_action(String.t(), %{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()} | {:snooze, integer()}
  def execute_email_action(action, args) do
    case action do
      "send_confirmation_emails" ->
        handle_confirmation_emails(args)

      "send_cancellation_emails" ->
        handle_cancellation_emails(args)

      "send_reminder_emails" ->
        handle_reminder_emails(args)

      "send_reschedule_request" ->
        handle_reschedule_request(args)

      "send_email_change_confirmations" ->
        handle_email_change_confirmations(args)

      "send_email_verification" ->
        handle_email_verification(args)

      "send_password_reset" ->
        handle_password_reset(args)

      "send_email_change_verification" ->
        handle_email_change_verification(args)

      "send_email_change_notification" ->
        handle_email_change_notification(args)

      "send_integration_unhealthy_notification" ->
        handle_integration_unhealthy_notification(args)

      _other ->
        {:discard, "Unknown action: #{action}"}
    end
  end

  defp handle_confirmation_emails(%{"meeting_id" => meeting_id}) do
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

  defp handle_reminder_emails(%{"meeting_id" => meeting_id} = args) do
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

  defp handle_reschedule_request(%{"meeting_id" => meeting_id}) do
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

  defp handle_cancellation_emails(%{"meeting_id" => meeting_id}) do
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
      case MeetingQueries.append_reminder_sent(meeting, reminder_value, reminder_unit) do
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
    Logger.info("Reminder emails sent",
      reminder_value: val,
      reminder_unit: unit,
      meeting_id: meeting.id,
      organizer_sent: organizer_success,
      attendee_sent: attendee_success
    )
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

  defp handle_email_verification(%{"user_id" => user_id, "verification_url" => verification_url}) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_email_verification(user, verification_url) do
          {:ok, _result} ->
            Logger.info("Queued email verification sent", user_id: user_id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to send email verification",
              user_id: user_id,
              error: inspect(reason)
            )

            {:error, "Failed to send email verification"}
        end

      {:error, :not_found} ->
        Logger.warning("User not found for email verification", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  defp handle_password_reset(%{"user_id" => user_id, "reset_url" => reset_url}) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_password_reset(user, reset_url) do
          {:ok, _result} ->
            Logger.info("Queued password reset email sent", user_id: user_id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to send password reset email",
              user_id: user_id,
              error: inspect(reason)
            )

            {:error, "Failed to send password reset email"}
        end

      {:error, :not_found} ->
        Logger.warning("User not found for password reset email", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  defp handle_email_change_verification(%{
         "user_id" => user_id,
         "new_email" => new_email,
         "verification_url" => verification_url
       }) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_email_change_verification(
               user,
               new_email,
               verification_url
             ) do
          {:ok, _result} ->
            Logger.info("Queued email change verification sent",
              user_id: user_id,
              new_email: new_email
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to send email change verification",
              user_id: user_id,
              new_email: new_email,
              error: inspect(reason)
            )

            {:error, "Failed to send email change verification"}
        end

      {:error, :not_found} ->
        Logger.warning("User not found for email change verification", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  defp handle_email_change_notification(%{"user_id" => user_id, "new_email" => new_email}) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_email_change_notification(user, new_email) do
          {:ok, _result} ->
            Logger.info("Queued email change notification sent",
              user_id: user_id,
              new_email: new_email
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to send email change notification",
              user_id: user_id,
              new_email: new_email,
              error: inspect(reason)
            )

            {:error, "Failed to send email change notification"}
        end

      {:error, :not_found} ->
        Logger.warning("User not found for email change notification", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  defp handle_email_change_confirmations(%{
         "user_id" => user_id,
         "old_email" => old_email,
         "new_email" => new_email
       }) do
    with {:ok, user} <- UserQueries.get_user(user_id),
         {old_result, new_result} <-
           email_service_module().send_email_change_confirmations(user, old_email, new_email) do
      organizer_success = match?({:ok, _result}, old_result)
      new_success = match?({:ok, _result}, new_result)

      Logger.info("Email change confirmations sent",
        user_id: user_id,
        old_sent: organizer_success,
        new_sent: new_success
      )

      if organizer_success and new_success do
        :ok
      else
        {:error, "One or more emails failed"}
      end
    else
      {:error, :not_found} ->
        Logger.warning("User not found for email change confirmations", user_id: user_id)
        {:discard, "User not found"}
    end
  end

  defp handle_integration_unhealthy_notification(%{
         "user_id" => user_id,
         "integration_id" => integration_id,
         "integration_type" => integration_type
       }) do
    with {:ok, user} <- UserQueries.get_user(user_id),
         {:ok, integration} <- fetch_integration(integration_type, integration_id) do
      type_atom = safe_integration_type_atom(integration_type)

      case email_service_module().send_integration_unhealthy_notification(
             user,
             integration,
             type_atom
           ) do
        {:ok, _result} ->
          Logger.info("Integration unhealthy notification sent",
            user_id: user_id,
            integration_id: integration_id,
            type: integration_type
          )

          IntegrationHealthStateQueries.update_fields(
            integration_type,
            integration_id,
            notification_sent_at: DateTime.utc_now()
          )

          :ok

        {:error, reason} ->
          Logger.error("Failed to send integration unhealthy notification",
            user_id: user_id,
            integration_id: integration_id,
            error: inspect(reason)
          )

          {:error, "Failed to send notification"}
      end
    else
      {:error, :not_found} ->
        Logger.warning("User or integration not found for unhealthy notification",
          user_id: user_id,
          integration_id: integration_id
        )

        {:discard, "User or integration not found"}
    end
  end

  defp fetch_integration("calendar", integration_id),
    do: CalendarIntegrationQueries.get(integration_id)

  defp fetch_integration("video", integration_id),
    do: VideoIntegrationQueries.get(integration_id)

  defp fetch_integration(_type, _id), do: {:error, :not_found}

  defp safe_integration_type_atom("calendar"), do: :calendar
  defp safe_integration_type_atom("video"), do: :video

  defp safe_integration_type_atom(type) do
    Logger.warning("Unknown integration type in email worker", type: type)
    :unknown
  end

  defp email_service_module do
    Application.get_env(:tymeslot, :email_service_module) ||
      Application.get_env(:tymeslot, :email_service) ||
      Tymeslot.Emails.EmailService
  end
end
