defmodule Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails do
  @moduledoc """
  Fan-out for group-meeting cancellation and reminder emails.

  Solo meetings carry one attendee on the meeting row, so a single pair of
  organiser/attendee emails is enough. Group meetings carry one live
  `meeting_participants` row per booker, so every live participant needs
  their own email — rendered through `Meetings.meeting_as_seen_by/2` so it
  reflects their own name, locale, and (for cancellation) their own cancel
  ICS — plus one organiser email carrying a participant-count label instead
  of a single attendee name.

  Split out of `Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails`, which
  still owns the solo-meeting paths and the meeting-level bookkeeping
  (`process_email_results/4`) shared by both.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Recipient

  @doc """
  One cancellation email per live participant (each with the cancel ICS for
  their own calendar copy) plus one organiser email. Host emails are
  English-only by convention, so the organiser overlay's participant-count
  label is plain text.
  """
  @spec send_group_cancellation_emails(MeetingSchema.t(), [Recipient.t()]) ::
          :ok | {:discard, String.t()} | {:error, String.t()}
  def send_group_cancellation_emails(meeting, participants) do
    email_service = Config.email_service_module()

    organizer_details =
      AppointmentBuilder.from_meeting(%{
        meeting
        | attendee_name: "#{length(participants)} participants"
      })

    organizer_result =
      email_service.send_cancellation_email_to_organizer(
        meeting.organizer_email,
        organizer_details
      )

    participant_results =
      Enum.map(participants, fn recipient ->
        details =
          meeting
          |> Meetings.meeting_as_seen_by(recipient)
          |> AppointmentBuilder.from_meeting()

        email_service.send_cancellation_email_to_attendee(recipient.email, details)
      end)

    summarize_group_send(meeting, "cancellation", [organizer_result | participant_results])
  end

  @doc """
  One reminder per live participant, each rendered through the recipient
  overlay so locale and timezone are the participant's own, plus one
  organiser reminder with a participant-count label. Returns the
  `{organizer_result, attendee_result}` pair in the same shape as the solo
  path so the caller can drive `process_email_results/4` and the
  `reminders_sent` bookkeeping identically for both.
  """
  @spec send_group_reminder_emails(MeetingSchema.t(), [Recipient.t()], pos_integer(), String.t()) ::
          {{:ok, term()} | {:error, term()}, {:ok, term()} | {:error, term()}}
  def send_group_reminder_emails(meeting, participants, reminder_value, reminder_unit) do
    email_service = Config.email_service_module()
    reminder = %{value: reminder_value, unit: reminder_unit}

    organizer_details =
      AppointmentBuilder.from_meeting(
        %{meeting | attendee_name: "#{length(participants)} participants"},
        reminder
      )

    organizer_result =
      email_service.send_appointment_reminder_to_organizer(
        meeting.organizer_email,
        organizer_details
      )

    participant_results =
      Enum.map(participants, fn recipient ->
        details =
          meeting
          |> Meetings.meeting_as_seen_by(recipient)
          |> AppointmentBuilder.from_meeting(reminder)

        email_service.send_appointment_reminder_to_attendee(recipient.email, details)
      end)

    {organizer_result, summarize_participant_reminders(participant_results)}
  end

  defp summarize_participant_reminders(participant_results) do
    cond do
      Enum.any?(participant_results, &match?({:ok, _sent}, &1)) -> {:ok, :sent}
      participant_results == [] -> {:ok, :none}
      true -> {:error, "Failed to send participant reminders"}
    end
  end

  defp summarize_group_send(meeting, label, results) do
    successes = Enum.count(results, &match?({:ok, _sent}, &1))

    cond do
      successes == length(results) ->
        :ok

      successes > 0 ->
        Logger.warning("Partial group email failure",
          meeting_id: meeting.id,
          label: label,
          sent: successes,
          total: length(results)
        )

        {:discard, "Partial group #{label} email failure: retry would duplicate"}

      true ->
        {:error, "Failed to send #{label} emails"}
    end
  end
end
