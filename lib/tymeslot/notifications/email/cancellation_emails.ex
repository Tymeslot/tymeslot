defmodule Tymeslot.Notifications.Email.CancellationEmails do
  @moduledoc """
  Sends the notices for a whole meeting's cancellation: to the organiser, the
  attendee (or, on a group meeting, every live participant) and every guest.

  Unlike confirmations and reminders, a cancellation has no per-recipient
  sent flag on the meeting, so what stops a rescued job re-sending it is a
  claim on the job itself (`DeliveryClaims`): one for the organiser's copy,
  one for the attendee's (`ParticipantLegs`) and one for each guest. So the
  guests are told on this run whatever became of the participants' copies,
  and a retry writes only to whoever was missed. On a group meeting one
  claim covers the per-seat fan-out instead, which is itself safe to repeat
  (see `GroupMeetingEmails`).
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.HostManaged
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Notifications.Email.GroupMeetingEmails
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Email.ParticipantLegs
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.DeliveryClaims

  # The meeting was restored or moved on since the email was scheduled.
  @meeting_not_cancelled "Meeting not cancelled"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason), do: reason == @meeting_not_cancelled

  @spec handle_cancellation_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_cancellation_emails(%{"meeting_id" => meeting_id} = args, job_id) do
    MeetingEmails.with_meeting(meeting_id, "cancellation emails", fn meeting ->
      if meeting.status == :cancelled do
        send_cancellation_emails_for_meeting(meeting, seat_refund(args), job_id)
      else
        Logger.info("Skipping cancellation emails - meeting is not cancelled",
          meeting_id: meeting_id,
          status: meeting.status
        )

        {:discard, @meeting_not_cancelled}
      end
    end)
  end

  # What the host's cancellation of a group meeting does with its paid seats'
  # money, from the job's `"seat_refund"` argument. Absent from a job
  # persisted before the argument existed, and from a meeting nobody paid for:
  # read as no refund, which is what the organiser is told they still hold.
  defp seat_refund(%{"seat_refund" => "full"}), do: :full
  defp seat_refund(_args), do: :none

  defp send_cancellation_emails_for_meeting(meeting, seat_refund, job_id) do
    appointment_details = AppointmentBuilder.from_meeting(meeting)
    Logger.info("Sending cancellation emails", meeting_id: meeting.id)

    participants =
      send_participant_cancellations(meeting, appointment_details, seat_refund, job_id)

    guests =
      GuestNotifications.notify_cancelled(
        meeting,
        appointment_details,
        &DeliveryClaims.once(job_id, &1, &2)
      )

    # A failure that a retry can fix outweighs a rejected address, so a
    # suppressed attendee never stops a guest's retry.
    DeliveryOutcome.combine("cancellation", [meeting_id: meeting.id], [participants, guests])
  end

  defp send_participant_cancellations(meeting, appointment_details, seat_refund, job_id) do
    if Meetings.group?(meeting) do
      DeliveryClaims.once(job_id, "cancellation:participants", fn ->
        # `group?/1` is capacity-based, not "has live participants": a meeting
        # emptied by every participant leaving is still a group meeting. Each
        # of them was told when they left, and so was the organiser: the last
        # leaver's seat email (or the last mover's) says the slot is now
        # empty and free. A second, meeting-level email here would only
        # repeat that with nobody to name, so the emptied meeting sends
        # nothing more.
        case Meetings.recipients(meeting) do
          [] ->
            :ok

          participants ->
            GroupMeetingEmails.send_group_cancellation_emails(meeting, participants, seat_refund)
        end
      end)
    else
      service = Config.email_service_module()

      ParticipantLegs.deliver(
        job_id,
        "cancellation",
        meeting.id,
        fn ->
          service.send_cancellation_email_to_organizer(
            appointment_details.organizer_email,
            AppointmentBuilder.organizer_copy(appointment_details, meeting)
          )
        end,
        fn -> attendee_copy(meeting, service, appointment_details) end
      )
    end
  end

  # A meeting the host manages (confirmed from a poll) has no booker: the
  # person in its attendee fields is a guest, invited, reminded and told of
  # changes with the other guests, so the booking emails with their
  # reschedule and cancel links are never sent to them.
  defp attendee_copy(meeting, service, appointment_details) do
    if HostManaged.managed?(meeting),
      do: {:ok, :skipped},
      else:
        service.send_cancellation_email_to_attendee(
          appointment_details.attendee_email,
          appointment_details
        )
  end
end
