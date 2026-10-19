defmodule Tymeslot.Notifications.Email.RescheduleEmails do
  @moduledoc """
  Sends the notices for a booking that moved: to the organiser, the attendee
  and every guest, each with an updated calendar entry.

  Two moves end here (`Tymeslot.Notifications.Orchestrator` validates and
  enqueues both):

    * a reschedule, whose job carries the time it moved from (`"original"`),
      since the meeting row no longer has it, so the emails can show both;
    * a booking whose new time the host has just approved after a reschedule
      sent it back into the approval gate (no `"original"`): the time it
      moved from is gone by then, so these notices carry the new time alone,
      and only the guests who had been invited are written to.

  Each copy is claimed on the job (`DeliveryClaims`), as for a cancellation:
  the organiser's and the attendee's (`ParticipantLegs`) and each guest's,
  so a rescued run repeats nothing already sent. Every copy is attempted on
  each run; a failed one retries the job, which then writes only to whoever
  was missed, and an open mail circuit snoozes it, as for every other
  booking email.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Email.ParticipantLegs
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.DeliveryClaims

  # A notice overtaken by events since the move it announces. The cancelled
  # reason is the one `MeetingEmails` gives, the void-slot one the one
  # `SeatJobs` gives.
  @meeting_cancelled "Meeting cancelled"
  @meeting_closed "Meeting expired or completed"
  @slot_void "Meeting time no longer holds"
  @moved_again "Meeting moved again"
  @status_changed "Meeting status changed"
  @meeting_started "Meeting already started"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do:
      reason in [
        @meeting_cancelled,
        @meeting_closed,
        @slot_void,
        @moved_again,
        @status_changed,
        @meeting_started
      ]

  @doc """
  Sends the notices for the move the job announces, unless the booking has
  moved on since: cancelled, expired or completed, sent back for a new time,
  moved again (the later move's own job tells everyone the time it now has),
  approved or declined into another status, or already started. Each of those discards the job
  rather than sending times nobody should act on.
  """
  @spec handle_reschedule_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_emails(%{"meeting_id" => meeting_id} = args, job_id) do
    MeetingEmails.with_meeting(meeting_id, "reschedule emails", fn meeting ->
      case overtaken(meeting, args) do
        nil ->
          send_reschedule_emails(meeting, Map.get(args, "original"), job_id)

        reason ->
          Logger.info("Skipping reschedule emails overtaken by a later change",
            meeting_id: meeting_id,
            reason: reason
          )

          {:discard, reason}
      end
    end)
  end

  defp overtaken(meeting, args) do
    cond do
      MeetingState.cancelled?(meeting) -> @meeting_cancelled
      MeetingState.terminal?(meeting) -> @meeting_closed
      MeetingState.slot_void?(meeting) -> @slot_void
      moved_again?(meeting, args["rescheduled_to"]) -> @moved_again
      status_changed?(meeting, args["status"]) -> @status_changed
      DateTime.compare(meeting.start_time, Clock.utc_now()) != :gt -> @meeting_started
      true -> nil
    end
  end

  # Jobs enqueued before the move's time and status were carried have
  # neither, and are judged on the rest.
  defp moved_again?(_meeting, nil), do: false

  defp moved_again?(meeting, rescheduled_to),
    do: DateTime.compare(meeting.start_time, parse_datetime(rescheduled_to)) != :eq

  defp status_changed?(_meeting, nil), do: false
  defp status_changed?(meeting, status), do: meeting.status != status

  # Each copy, the organiser's, the attendee's and each guest's, is claimed
  # for the job, so the guests are told on this run whatever became of the
  # participants' copies, and a retry writes only to whoever was missed.
  defp send_reschedule_emails(meeting, original, job_id) do
    content = content(meeting, original)
    service = Config.email_service_module()

    participants =
      ParticipantLegs.deliver(
        job_id,
        "reschedule",
        meeting.id,
        fn -> service.send_reschedule_email_to_organizer(content.organizer_email, content) end,
        fn -> service.send_reschedule_email_to_attendee(content.attendee_email, content) end
      )

    guests = notify_guests(meeting, content, original, &DeliveryClaims.once(job_id, &1, &2))

    # Every copy was attempted; a failure that a retry can fix outweighs a
    # rejected address, so a suppressed attendee never stops a guest's retry.
    DeliveryOutcome.combine("reschedule", [meeting_id: meeting.id], [participants, guests])
  end

  defp notify_guests(meeting, content, nil, once),
    do: GuestNotifications.notify_reapproved(meeting, content, once)

  defp notify_guests(meeting, content, _original, once),
    do: GuestNotifications.notify_rescheduled(meeting, content, once)

  defp content(meeting, nil), do: AppointmentBuilder.for_reapproval(meeting)

  defp content(meeting, original) do
    AppointmentBuilder.for_reschedule(meeting, %{
      start_time: parse_datetime(original["start_time"]),
      end_time: parse_datetime(original["end_time"]),
      attendee_video_url: original["attendee_video_url"]
    })
  end

  defp parse_datetime(iso) when is_binary(iso) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso)
    datetime
  end
end
