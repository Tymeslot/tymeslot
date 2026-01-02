defmodule Tymeslot.Workers.EmailWorkerHandlers do
  @moduledoc """
  Internal handlers for EmailWorker actions.
  """

  require Logger
  alias Tymeslot.DatabaseQueries.{MeetingQueries, UserQueries}
  alias Tymeslot.Emails.AppointmentBuilder

  @doc """
  Executes the specified email action with the given arguments.

  This is the primary entry point for the EmailWorker to process various types of
  email jobs, including confirmations, reminders, and authentication emails.

  Returns `:ok` on success, `{:error, reason}` for retriable failures,
  `{:discard, reason}` for fatal errors that shouldn't be retried,
  or `{:snooze, seconds}` if the job should be delayed.
  """
  @spec execute_email_action(String.t(), map()) ::
          :ok | {:error, term()} | {:discard, String.t()} | {:snooze, integer()}
  def execute_email_action(action, args) do
    case action do
      "send_confirmation_emails" ->
        handle_confirmation_emails(args)

      "send_reminder_emails" ->
        handle_reminder_emails(args)

      "send_reschedule_request" ->
        handle_reschedule_request(args)

      "send_contact_form" ->
        handle_contact_form(args)

      "send_email_verification" ->
        handle_email_verification(args)

      "send_password_reset" ->
        handle_password_reset(args)

      "send_email_change_verification" ->
        handle_email_change_verification(args)

      "send_email_change_notification" ->
        handle_email_change_notification(args)

      "send_email_change_confirmations" ->
        handle_email_change_confirmations(args)

      _ ->
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

        {:error, :meeting_not_found}
    end
  end

  defp handle_reminder_emails(%{"meeting_id" => meeting_id}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        if meeting.status == "cancelled" do
          Logger.info("Skipping reminder emails for cancelled meeting",
            meeting_id: meeting_id
          )

          {:error, :meeting_cancelled}
        else
          send_reminder_emails(meeting)
        end

      {:error, :not_found} ->
        Logger.warning("Attempted to send reminder emails for non-existent meeting",
          meeting_id: meeting_id
        )

        {:error, :meeting_not_found}
    end
  end

  defp handle_reschedule_request(%{"meeting_id" => meeting_id}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        if meeting.status == "cancelled" do
          Logger.info("Skipping reschedule request for cancelled meeting",
            meeting_id: meeting_id
          )

          {:error, :meeting_cancelled}
        else
          send_reschedule_request_email(meeting)
        end

      {:error, :not_found} ->
        Logger.warning("Attempted to send reschedule request for non-existent meeting",
          meeting_id: meeting_id
        )

        {:error, :meeting_not_found}
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

      organizer_result =
        if need_organizer? do
          email_service_module().send_appointment_confirmation_to_organizer(
            appointment_details.organizer_email,
            appointment_details
          )
        else
          {:ok, :skipped}
        end

      attendee_result =
        if need_attendee? do
          email_service_module().send_appointment_confirmation_to_attendee(
            appointment_details.attendee_email,
            appointment_details
          )
        else
          {:ok, :skipped}
        end

      process_email_results(meeting, organizer_result, attendee_result, :confirmation)
    end
  end

  defp send_reminder_emails(meeting) do
    Logger.info("Sending reminder emails", meeting_id: meeting.id, uid: meeting.uid)

    appointment_details = AppointmentBuilder.from_meeting(meeting)

    case email_service_module().send_appointment_reminders(appointment_details, "30 minutes") do
      {organizer_result, attendee_result} ->
        process_email_results(meeting, organizer_result, attendee_result, :reminder)
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

  defp process_email_results(meeting, organizer_result, attendee_result, email_type) do
    organizer_success = match?({:ok, _}, organizer_result)
    attendee_success = match?({:ok, _}, attendee_result)

    error_result = check_email_errors(organizer_result, attendee_result)

    case error_result do
      nil ->
        update_email_sent_flags(meeting, email_type, organizer_success, attendee_success)
        log_email_results(meeting, email_type, organizer_success, attendee_success)

        if organizer_success && attendee_success do
          :ok
        else
          {:error, "Failed to send all emails"}
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

          _ ->
            nil
        end
    end
  end

  defp update_email_sent_flags(meeting, :confirmation, organizer_success, attendee_success) do
    if organizer_success and not meeting.organizer_email_sent do
      {:ok, _} = MeetingQueries.mark_email_sent(meeting, :organizer)
    end

    if attendee_success and not meeting.attendee_email_sent do
      {:ok, _} = MeetingQueries.mark_email_sent(meeting, :attendee)
    end
  end

  defp update_email_sent_flags(meeting, :reminder, organizer_success, attendee_success) do
    if organizer_success || attendee_success do
      {:ok, _} = MeetingQueries.mark_email_sent(meeting, :reminder)
    end
  end

  defp log_email_results(meeting, email_type, organizer_success, attendee_success) do
    Logger.info("#{email_type} emails sent",
      meeting_id: meeting.id,
      organizer_sent: organizer_success,
      attendee_sent: attendee_success
    )
  end

  defp handle_contact_form(args) do
    required = ["sender_name", "sender_email", "subject", "message"]
    missing = Enum.reject(required, &Map.has_key?(args, &1))

    if missing != [] do
      Logger.error("Contact form email missing required fields", missing: missing)
      {:discard, "Missing required fields: #{Enum.join(missing, ", ")}"}
    else
      sender_name = Map.fetch!(args, "sender_name")
      sender_email = Map.fetch!(args, "sender_email")
      subject = Map.fetch!(args, "subject")
      message = Map.fetch!(args, "message")

      Logger.info("Sending contact form email", sender_email: sender_email, subject: subject)

      case email_service_module().send_contact_form(sender_name, sender_email, subject, message) do
        {:ok, _result} ->
          Logger.info("Contact form email sent successfully",
            sender_email: sender_email,
            subject: subject
          )

          :ok

        {:error, reason} ->
          Logger.error("Failed to send contact form email",
            sender_email: sender_email,
            subject: subject,
            error: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  defp handle_email_verification(%{"user_id" => user_id, "verification_url" => verification_url}) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        case email_service_module().send_email_verification(user, verification_url) do
          {:ok, _} ->
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
          {:ok, _} ->
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
          {:ok, _} ->
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
          {:ok, _} ->
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
      organizer_success = match?({:ok, _}, old_result)
      new_success = match?({:ok, _}, new_result)

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

  defp email_service_module do
    Application.get_env(:tymeslot, :email_service_module) ||
      Application.get_env(:tymeslot, :email_service) ||
      Tymeslot.Emails.EmailService
  end
end
