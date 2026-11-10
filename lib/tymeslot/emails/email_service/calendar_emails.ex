defmodule Tymeslot.Emails.EmailService.CalendarEmails do
  @moduledoc "Calendar-related emails: sync errors, external booking changes, invitations, and reschedule requests."

  require Logger

  alias Tymeslot.Emails.BookingDelivery
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

  Sent by `Tymeslot.Meetings.CalendarEventSync` when a booking's calendar
  event cannot be written: at once when the calendar declines the create
  (`:refused`, which no retry changes), and otherwise once the create, or an
  update that cannot be applied, has spent its last attempt, including a
  create given up on after waiting out an unreachable calendar. An
  unauthorised write sends the integration's reconnection notice instead.
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
  (`:attendees`) and how many guests were (`:guests`). The summary uses the
  same booking sender as the attendee and guest notices.
  """
  @spec send_end_change_to_organizer(map(), String.t(), ExternalBookingChange.end_notice()) ::
          {:ok, any()} | {:error, any()}
  def send_end_change_to_organizer(meeting, organizer_email, notice) do
    Logger.info("Sending external end change notice", meeting_id: meeting.id)

    BookingDelivery.deliver(meeting, fn meeting ->
      ExternalBookingChange.render_end_followed(
        meeting,
        organizer_email,
        notice,
        HostClock.timezone(meeting)
      )
    end)
  end

  @doc """
  Sends a dashboard event invitation or cancellation using its organizer's sender.

  Trusted invitation details retain the organizer ID even after the event is
  removed. The actual organizer remains the reply and calendar identity.
  """
  @spec send_calendar_invitation(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_calendar_invitation(attendee_email, invitation_details) do
    Logger.info("Sending calendar invitation")

    BookingDelivery.deliver(invitation_details, fn details ->
      CalendarInvitation.render(attendee_email, details)
    end)
  end

  @doc """
  Sends an event update using the sender shared by its execution's recipient copies.

  The change summary and updated calendar entry retain the actual organizer.
  """
  @spec send_event_update_notification(String.t(), map()) :: {:ok, any()} | {:error, any()}
  def send_event_update_notification(attendee_email, update_details) do
    Logger.info("Sending event update notification")

    BookingDelivery.deliver(update_details, fn details ->
      EventUpdateNotification.render(attendee_email, details)
    end)
  end

  @doc """
  Sends a reschedule request email.
  """
  @spec send_reschedule_request(map()) :: {:ok, any()} | {:error, any()}
  def send_reschedule_request(meeting) do
    Logger.info("Sending reschedule request", meeting_id: meeting.id)

    BookingDelivery.deliver(meeting, &RescheduleRequest.render/1)
  end
end
