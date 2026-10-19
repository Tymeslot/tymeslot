defmodule Tymeslot.Emails.EmailService.CalendarEmails do
  @moduledoc "Calendar-related emails: sync errors, external booking changes, invitations, and reschedule requests."

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.HostClock
  alias Tymeslot.Infrastructure.AdminAlerts

  alias Tymeslot.Emails.Templates.{
    CalendarInvitation,
    CalendarSyncError,
    EventUpdateNotification,
    ExternalBookingChange,
    RescheduleRequest
  }

  @doc """
  Sends a calendar sync error notification to the calendar owner.
  This is only sent when calendar event creation fails after all retries.
  """
  @spec send_calendar_sync_error(map(), any()) :: {:ok, any()} | {:error, any()}
  def send_calendar_sync_error(meeting, error_reason) do
    owner_email = CalendarSyncError.recipient_email(meeting)

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

    # The operator is alerted before the email is rendered, so a template
    # that fails to render cannot swallow the alert.
    meeting
    |> CalendarSyncError.render(error_reason)
    |> Delivery.deliver()
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

    owner_timezone = HostClock.timezone(meeting)

    result =
      Delivery.deliver(
        ExternalBookingChange.render(meeting, organizer_email, discrepancy, owner_timezone)
      )

    Logger.info("External booking change notification sent",
      sent: match?({:ok, _}, result),
      discrepancy: discrepancy
    )

    result
  end

  @doc """
  Tells an organiser that a meeting now ends where they moved its end in their
  own calendar, and who was emailed the new end. `notice` carries the end it
  had before (`:previous_end_time`), the names of the attendees reached
  (`:attendees`) and how many guests were (`:guests`).
  """
  @spec send_end_change_to_organizer(map(), String.t(), ExternalBookingChange.end_notice()) ::
          {:ok, any()} | {:error, any()}
  def send_end_change_to_organizer(meeting, organizer_email, notice) do
    Logger.info("Sending external end change notice", meeting_id: meeting.id)

    meeting
    |> ExternalBookingChange.render_end_followed(
      organizer_email,
      notice,
      HostClock.timezone(meeting)
    )
    |> Delivery.deliver()
  end

  @doc """
  Sends a calendar invitation email to an attendee for a dashboard-created event.
  """
  @spec send_calendar_invitation(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_calendar_invitation(attendee_email, invitation_details) do
    Logger.info("Sending calendar invitation")

    attendee_email
    |> CalendarInvitation.render(invitation_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends an event update notification to an attendee with a change summary and updated .ics.
  """
  @spec send_event_update_notification(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_event_update_notification(attendee_email, update_details) do
    Logger.info("Sending event update notification")

    attendee_email
    |> EventUpdateNotification.render(update_details)
    |> Delivery.deliver()
  end

  @doc """
  Sends a reschedule request email.
  """
  @spec send_reschedule_request(map()) :: {:ok, any()} | {:error, any()}
  def send_reschedule_request(meeting) do
    Logger.info("Sending reschedule request", meeting_id: meeting.id)

    email = RescheduleRequest.render(meeting)
    Delivery.deliver(email)
  end
end
