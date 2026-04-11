defmodule Tymeslot.Emails.EmailService.CalendarEmails do
  @moduledoc "Calendar-related emails: sync errors, external booking changes, invitations, and reschedule requests."

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Profiles

  alias Tymeslot.Emails.Templates.{
    CalendarInvitation,
    CalendarSyncError,
    EventUpdateNotification,
    ExternalBookingChange,
    RescheduleRequest
  }

  alias Swoosh.Email

  @doc """
  Sends a calendar sync error notification to the calendar owner.
  This is only sent when calendar event creation fails after all retries.
  """
  @spec send_calendar_sync_error(map(), any()) :: {:ok, any()} | {:error, any()}
  def send_calendar_sync_error(meeting, error_reason) do
    owner_email =
      meeting.organizer_email ||
        Application.get_env(:tymeslot, :email)[:from_email] ||
        System.get_env("POSTMARK_FROM_EMAIL")

    Logger.info("Sending calendar sync error notification",
      meeting_id: meeting.id,
      organizer_email: owner_email
    )

    AdminAlerts.report(:calendar_sync_error,
      summary: "Calendar sync failed for meeting",
      reason: error_reason,
      context: %{
        meeting_id: meeting.id,
        owner_email: owner_email,
        calendar_integration_id: Map.get(meeting, :calendar_integration_id)
      }
    )

    {html_body, text_body} = CalendarSyncError.render_both(meeting, error_reason)

    email =
      MjmlEmail.base_email()
      |> Email.to({meeting.organizer_name || "Calendar Owner", owner_email})
      |> Email.subject("⚠️ Calendar Sync Error - Manual Action Required")
      |> Email.html_body(html_body)
      |> Email.text_body(text_body)

    Delivery.deliver(email)
  end

  @doc """
  Notifies an organizer that one of their meetings was changed in their external calendar.

  `discrepancy` is either `:deleted` (the event was removed from the external calendar)
  or `:modified` (the event was rescheduled in the external calendar).
  """
  @spec send_external_booking_change(map(), String.t(), ExternalBookingChange.discrepancy()) ::
          {:ok, any()} | {:error, any()}
  def send_external_booking_change(meeting, organizer_email, discrepancy) do
    Logger.info("Sending external booking change notification",
      meeting_id: meeting.id,
      organizer_email: organizer_email,
      discrepancy: discrepancy
    )

    owner_timezone = resolve_owner_timezone(meeting)

    result =
      Delivery.deliver(
        ExternalBookingChange.build_email(meeting, organizer_email, discrepancy, owner_timezone)
      )

    Logger.info("External booking change notification sent",
      sent: match?({:ok, _}, result),
      discrepancy: discrepancy
    )

    result
  end

  @doc """
  Sends a calendar invitation email to an attendee for a dashboard-created event.
  """
  @spec send_calendar_invitation(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_calendar_invitation(attendee_email, invitation_details) do
    Logger.info("Sending calendar invitation",
      title: invitation_details[:event_title],
      to: attendee_email
    )

    attendee_email
    |> CalendarInvitation.invitation_email(invitation_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends an event update notification to an attendee with a change summary and updated .ics.
  """
  @spec send_event_update_notification(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_event_update_notification(attendee_email, update_details) do
    Logger.info("Sending event update notification",
      title: update_details[:event_title],
      to: attendee_email
    )

    attendee_email
    |> EventUpdateNotification.update_notification_email(update_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends a reschedule request email.
  """
  @spec send_reschedule_request(map()) :: {:ok, any()} | {:error, any()}
  def send_reschedule_request(meeting) do
    Logger.info("Sending reschedule request",
      meeting_id: meeting.id,
      to: meeting.attendee_email
    )

    email = RescheduleRequest.reschedule_request_email(meeting)
    Delivery.deliver(email)
  end

  defp resolve_owner_timezone(%{organizer_user_id: nil}), do: Profiles.get_default_timezone()
  defp resolve_owner_timezone(%{organizer_user_id: id}), do: Profiles.get_user_timezone(id)
  defp resolve_owner_timezone(_meeting), do: Profiles.get_default_timezone()
end
