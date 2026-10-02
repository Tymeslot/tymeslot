defmodule Tymeslot.Workers.EmailWorkerHandlers.SeatEmails do
  @moduledoc """
  The emails for one seat's own lifecycle on a group meeting: booked,
  cancelled by its participant, and moved to another time. (A participant's
  copy of a whole-meeting event, a reminder or the host's cancellation, is
  `Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails`.)

  Each job sends to more than one recipient: the participant, the organiser,
  and the participant's guests. Every delivery is recorded as it succeeds, so
  a retry sends only what has not gone out and the job keeps retrying until
  everything has:

    * a confirmation and a move stamp the seat's `confirmation_sent_at`
      (the participant) and `organizer_notified_at` (the organiser), as a
      solo booking stamps its `*_email_sent` flags. A move is a fresh seat
      row, so its stamps start empty;
    * a cancellation claims each send on the job (`DeliveryClaims`), since the
      seat's stamps were spent on its confirmation;
    * guests are stamped or claimed one by one and never fail the job.

  Each seat is its own calendar entry for its participant and their guests
  (`Tymeslot.Meetings.ParticipantSchema.calendar_uid/1`): the confirmation
  invites to it, a cancellation cancels it one revision up, and a move
  cancels the old seat's entry and invites to the new one's. The organiser's
  emails carry no calendar file at all: their calendar holds the slot as one
  provider event Tymeslot keeps up to date itself, and the solo organiser
  emails leave the file off for the same reason (an invitation-processing
  mail server would import it as a second event).
  """

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.GuestEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.SeatJobs

  @doc """
  A booked seat: the participant's confirmation, the organiser's "a spot was
  booked", and invitations for the participant's guests.
  """
  @spec handle_seat_confirmation_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_confirmation_emails(%{
        "meeting_id" => meeting_id,
        "participant_id" => participant_id
      }) do
    SeatJobs.with_seat(
      meeting_id,
      participant_id,
      "seat confirmation emails",
      {:live_slot, :live},
      &send_confirmation/2
    )
  end

  @doc """
  A seat its participant cancelled: their cancellation, the organiser's "a
  participant cancelled their spot" (unless `notify_organizer` is false, when
  the seat was the last and the meeting-level cancellation tells the
  organiser instead), and cancellations for the participant's guests.
  """
  @spec handle_seat_cancellation_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_cancellation_emails(
        %{"meeting_id" => meeting_id, "participant_id" => participant_id} = args,
        job_id
      ) do
    notify_organizer? = Map.get(args, "notify_organizer", true)

    SeatJobs.with_seat(
      meeting_id,
      participant_id,
      "seat cancellation emails",
      {:any, :cancelled},
      &send_cancellation(&1, &2, notify_organizer?, job_id)
    )
  end

  @doc """
  A seat moved to another time: the participant's confirmation of the new
  seat with a cancellation of the old one attached, the organiser's "a
  participant moved their spot", a cancellation of the old seat for the
  participant's guests and an invitation to the new one.

  `participant_id` is the seat at its new time, `old_participant_id` the
  cancelled seat it moved from.
  """
  @spec handle_seat_reschedule_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_reschedule_emails(
        %{
          "meeting_id" => meeting_id,
          "participant_id" => participant_id,
          "old_participant_id" => old_participant_id
        },
        job_id
      ) do
    SeatJobs.with_seat(
      meeting_id,
      participant_id,
      "seat reschedule emails",
      {:live_slot, :live},
      &send_reschedule(&1, &2, old_seat(old_participant_id), job_id)
    )
  end

  defp send_confirmation(meeting, participant) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    email_service = Config.email_service_module()

    attendee_result =
      unless_stamped(participant, :confirmation_sent_at, fn ->
        email_service.send_appointment_confirmation_to_attendee(recipient.email, details)
      end)

    organizer_result =
      unless_stamped(participant, :organizer_notified_at, fn ->
        email_service.send_seat_update_to_organizer(
          :booked,
          meeting.organizer_email,
          AppointmentBuilder.for_organizer_of_seat(meeting, recipient)
        )
      end)

    invite_guests(meeting, participant, details, email_service)

    DeliveryOutcome.from_results(
      "seat confirmation",
      [meeting_id: meeting.id, participant_id: participant.id],
      [organizer_result, attendee_result]
    )
  end

  # The participant's payload is built from their cancelled row, whose
  # `ical_sequence` already records the cancellation's revision; the payload
  # carries the invitation's (see `ParticipantSchema.invitation_sequence/1`)
  # and the cancellation template stamps its file one above it, on the seat's
  # own UID. Their guests share that entry, so they get the same.
  defp send_cancellation(meeting, participant, notify_organizer?, job_id) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    email_service = Config.email_service_module()

    attendee_result =
      DeliveryClaims.once(job_id, "seat_cancellation:participant", fn ->
        email_service.send_cancellation_email_to_attendee(recipient.email, details)
      end)

    organizer_result =
      if notify_organizer? do
        DeliveryClaims.once(job_id, "seat_cancellation:organizer", fn ->
          email_service.send_seat_update_to_organizer(
            :cancelled,
            meeting.organizer_email,
            AppointmentBuilder.for_organizer_of_seat(meeting, recipient)
          )
        end)
      else
        {:ok, :skipped}
      end

    GuestNotifications.notify_seat_cancelled(
      meeting,
      GuestQueries.list_for_participant(participant.id),
      details,
      &DeliveryClaims.once(job_id, &1, &2)
    )

    DeliveryOutcome.from_results(
      "seat cancellation",
      [meeting_id: meeting.id, participant_id: participant.id],
      [organizer_result, attendee_result]
    )
  end

  defp send_reschedule(meeting, participant, old_seat, job_id) do
    recipient = Recipient.from_participant(participant)
    details = AppointmentBuilder.from_meeting(meeting, recipient, nil)
    email_service = Config.email_service_module()

    attendee_result =
      unless_stamped(participant, :confirmation_sent_at, fn ->
        send_moved_seat_to_participant(email_service, recipient.email, details, old_seat)
      end)

    organizer_result =
      unless_stamped(participant, :organizer_notified_at, fn ->
        email_service.send_seat_update_to_organizer(
          :moved,
          meeting.organizer_email,
          meeting
          |> AppointmentBuilder.for_organizer_of_seat(recipient)
          |> put_original_time(old_seat)
        )
      end)

    cancel_old_guests(old_seat, job_id)
    invite_guests(meeting, participant, details, email_service)

    DeliveryOutcome.from_results(
      "seat reschedule",
      [meeting_id: meeting.id, participant_id: participant.id],
      [organizer_result, attendee_result]
    )
  end

  # The seat a move left, with its own payload: the old slot's time and the
  # old seat's calendar entry. `nil` when either row has since gone (data
  # retention), in which case the move is announced without cancelling an
  # entry nothing can name any more.
  defp old_seat(old_participant_id) do
    with {:ok, participant} <- ParticipantQueries.get(old_participant_id),
         {:ok, meeting} <- MeetingQueries.get_meeting(participant.meeting_id) do
      recipient = Recipient.from_participant(participant)

      %{
        meeting: meeting,
        participant: participant,
        details: AppointmentBuilder.from_meeting(meeting, recipient, nil)
      }
    else
      {:error, :not_found} -> nil
    end
  end

  defp send_moved_seat_to_participant(email_service, email, details, nil),
    do: email_service.send_appointment_confirmation_to_attendee(email, details)

  defp send_moved_seat_to_participant(email_service, email, details, %{details: old}) do
    old_event = %{
      uid: old.uid,
      ical_sequence: old.ical_sequence,
      start_time: old.start_time,
      end_time: old.end_time
    }

    email_service.send_seat_reschedule_to_participant(email, details, old_event)
  end

  defp put_original_time(details, nil), do: details

  defp put_original_time(details, %{details: old}),
    do: Map.put(details, :original_start_time_owner_tz, old.start_time_owner_tz)

  defp cancel_old_guests(nil, _job_id), do: :ok

  defp cancel_old_guests(%{meeting: meeting, participant: participant, details: details}, job_id) do
    GuestNotifications.notify_seat_cancelled(
      meeting,
      GuestQueries.list_for_participant(participant.id),
      details,
      &DeliveryClaims.once(job_id, &1, &2)
    )
  end

  # The participant's own guests not yet invited, from the participant's
  # payload: their language, their timezone, their seat's calendar entry.
  defp invite_guests(meeting, participant, details, email_service) do
    participant.id
    |> GuestQueries.list_unsent_for_participant()
    |> GuestEmails.send_confirmations(meeting, details, email_service)
  end

  # Sends unless this seat's `field` already records the send, and records it
  # once the send has succeeded, or once the provider has refused the address
  # outright, which no retry can change.
  defp unless_stamped(participant, field, send) do
    case Map.fetch!(participant, field) do
      %DateTime{} ->
        {:ok, :already_sent}

      nil ->
        result = send.()
        if settled?(result), do: stamp(participant, field)
        result
    end
  end

  defp stamp(participant, :confirmation_sent_at),
    do: ParticipantQueries.mark_confirmation_sent(participant)

  defp stamp(participant, :organizer_notified_at),
    do: ParticipantQueries.mark_organizer_notified(participant)

  defp settled?({:ok, _result}), do: true
  defp settled?({:error, {:recipient_rejected, _reason}}), do: true
  defp settled?(_result), do: false
end
