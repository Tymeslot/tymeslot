defmodule Tymeslot.Workers.EmailWorkerHandlers.GuestEmails do
  @moduledoc """
  The guest sends the meeting email handlers make: a booking's guests are
  invited alongside its confirmation and reminded alongside its reminders.

  Split out of `Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails` so the
  solo and group handlers (`GroupMeetingEmails`) share one send loop. Each
  guest is stamped on success, so a retry only reaches the guests a previous
  run missed, and a failed guest send never fails the job that made it.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Utils.ReminderUtils

  @doc """
  Invites whichever of the meeting's guests a previous confirmation run did
  not reach. Builds the payload only when there is somebody to send to, so
  the already-sent path stays one cheap query.
  """
  @spec invite_missed(MeetingSchema.t()) :: :ok
  def invite_missed(meeting) do
    case GuestQueries.list_unsent_for_meeting(meeting.id) do
      [] ->
        :ok

      unsent ->
        send_confirmations(
          unsent,
          meeting,
          AppointmentBuilder.from_meeting(meeting),
          Config.email_service_module()
        )
    end
  end

  @doc """
  Sends `email_service.send_guest_confirmation/2` to every guest in `guests`,
  stamping `confirmation_sent_at` on each successful send so a retry only
  re-attempts the ones still unsent. Failures are logged but never block the
  caller's own organiser/attendee result.

  Shared by `MeetingEmails` and `GroupMeetingEmails`: the loop is identical
  for a meeting's guests and one participant's guests, they only differ in how
  `guests` was queried (`GuestQueries.list_unsent_for_meeting/1` vs
  `GuestQueries.list_unsent_for_participant/1`).
  """
  @spec send_confirmations([GuestSchema.t()], MeetingSchema.t(), map(), module()) :: :ok
  def send_confirmations(guests, meeting, appointment_details, email_service) do
    Enum.each(guests, fn guest ->
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

    :ok
  end

  @doc """
  Reminds the meeting's guests for one configured offset, stamping each guest
  per offset so a retry after a partial send re-emails only the guests it has
  not reached. Failures are logged and never change the caller's result.
  """
  @spec send_reminders(MeetingSchema.t(), map(), term(), term()) :: :ok
  def send_reminders(meeting, appointment_details, reminder_value, reminder_unit) do
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

    :ok
  end
end
