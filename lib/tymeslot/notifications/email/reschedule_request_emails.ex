defmodule Tymeslot.Notifications.Email.RescheduleRequestEmails do
  @moduledoc """
  The email asking an attendee to pick a new time, after the host asked for
  the booking to be rescheduled, sent only while that request is still the
  one the meeting is waiting on.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Email.GroupMeetingEmails
  alias Tymeslot.Notifications.Email.MeetingEmails

  @meeting_cancelled "Meeting cancelled"
  @meeting_closed "Meeting expired or completed"
  @request_not_pending "Reschedule request no longer pending"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do: reason in [@meeting_cancelled, @meeting_closed, @request_not_pending]

  @spec handle_reschedule_request(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_request(%{"meeting_id" => meeting_id} = args) do
    MeetingEmails.with_meeting(meeting_id, "reschedule request", fn meeting ->
      cond do
        MeetingState.cancelled?(meeting) ->
          Logger.info("Skipping reschedule request for cancelled meeting",
            meeting_id: meeting_id
          )

          {:discard, @meeting_cancelled}

        MeetingState.terminal?(meeting) ->
          Logger.info("Skipping reschedule request for a meeting already over",
            meeting_id: meeting_id,
            status: meeting.status
          )

          {:discard, @meeting_closed}

        not request_pending?(meeting, args["requested_at"]) ->
          Logger.info("Skipping reschedule request no longer pending", meeting_id: meeting_id)
          {:discard, @request_not_pending}

        true ->
          send_reschedule_request_email(meeting)
      end
    end)
  end

  # The request this job announces is still the one the meeting is waiting
  # on: the attendee has not booked a new time since, and no later request
  # (which queues its own job) has replaced it. A job queued before the
  # request time was carried in its args has only the first check.
  defp request_pending?(meeting, nil), do: MeetingState.awaiting_new_time?(meeting)

  defp request_pending?(%{reschedule_requested_at: %DateTime{} = at}, requested_at)
       when is_binary(requested_at),
       do: DateTime.to_iso8601(at) == requested_at

  defp request_pending?(_meeting, _requested_at), do: false

  defp send_reschedule_request_email(meeting) do
    Logger.info("Sending reschedule request email", meeting_id: meeting.id)

    if Meetings.group?(meeting) do
      participants = Meetings.recipients(meeting)
      GroupMeetingEmails.send_group_reschedule_requests(meeting, participants)
    else
      send_solo_reschedule_request(meeting)
    end
  end

  # The solo counterpart to `GroupMeetingEmails.send_group_reschedule_requests/2`,
  # kept here (not there) since it is solo-only and this module already owns
  # every other solo-meeting send.
  defp send_solo_reschedule_request(meeting) do
    case Config.email_service_module().send_reschedule_request(meeting) do
      {:ok, _result} ->
        Logger.info("Reschedule request email sent successfully", meeting_id: meeting.id)

        :ok

      {:error, reason} ->
        Logger.error("Failed to send reschedule request email",
          meeting_id: meeting.id,
          error: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end
end
