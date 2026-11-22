defmodule Tymeslot.Notifications.Email.RescheduleRequestEmails do
  @moduledoc """
  The email asking an attendee to pick a new time, after the host asked for
  the booking to be rescheduled, sent only while that request is still the
  one the meeting is waiting on; and the two closing it when the attendee
  never answered (`Tymeslot.Bookings.RescheduleRequestExpiry`), one to the
  host and one to the attendee, or to each participant still on a group
  meeting.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Email.GroupMeetingEmails
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Relevance
  alias Tymeslot.Workers.DeliveryClaims

  @meeting_cancelled "Meeting cancelled"
  @meeting_closed "Meeting expired or completed"
  @request_not_pending "Reschedule request no longer pending"
  @past_deadline "Reschedule request past its deadline"
  @not_lapsed "Reschedule request did not lapse"

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
        @request_not_pending,
        @past_deadline,
        @not_lapsed
      ]

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
          with :ok <- check_answerable(meeting), do: send_reschedule_request_email(meeting)
      end
    end)
  end

  @doc """
  Whether the attendee can still answer the meeting's reschedule request:
  `:ok` until its deadline (`Relevance.reschedule_request/1`), a discard
  after it.

  Judged against the meeting as it stands when the email is about to go,
  never a moment frozen into the job: the deadline follows the meeting's
  start, which a host edit or a calendar sync can move while the job waits.
  """
  @spec check_answerable(map()) :: :ok | {:discard, String.t()}
  def check_answerable(meeting) do
    deadline = Relevance.reschedule_request(meeting)

    if Relevance.relevant?(deadline, Clock.utc_now()) do
      :ok
    else
      Logger.info("Skipping reschedule request past its deadline",
        meeting_id: meeting.id,
        deadline: deadline
      )

      {:discard, @past_deadline}
    end
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

  @doc """
  Tells the host their reschedule request lapsed unanswered and the meeting
  has expired, in the host's own language.
  """
  @spec handle_reschedule_request_unanswered(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_request_unanswered(%{"meeting_id" => meeting_id}) do
    MeetingEmails.with_meeting(meeting_id, "reschedule request unanswered", fn meeting ->
      with_lapsed_request(meeting, fn ->
        locale = RecipientLocale.locale_for_user_id(meeting.organizer_user_id)

        meeting
        |> Config.email_service_module().send_reschedule_request_unanswered(locale)
        |> send_result("reschedule request unanswered", meeting)
      end)
    end)
  end

  @doc """
  Tells the attendee, or each participant still on a group meeting, that the
  host's request to pick a new time has lapsed. Each send is claimed on the
  job, so a retry writes only to whoever a failed run missed.
  """
  @spec handle_reschedule_request_lapsed(%{String.t() => term()}, term()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_request_lapsed(%{"meeting_id" => meeting_id}, job_id) do
    MeetingEmails.with_meeting(meeting_id, "reschedule request lapsed", fn meeting ->
      with_lapsed_request(meeting, fn ->
        meeting
        |> Meetings.recipients()
        |> Enum.map(&send_lapsed_to(meeting, &1, job_id))
        |> Enum.find(:ok, &match?({:error, _reason}, &1))
      end)
    end)
  end

  defp with_lapsed_request(meeting, send_fun) do
    if MeetingState.expired?(meeting) and MeetingState.reschedule_request_lapsed?(meeting) do
      send_fun.()
    else
      Logger.info("Skipping lapsed reschedule request email - request did not lapse",
        meeting_id: meeting.id,
        status: meeting.status
      )

      {:discard, @not_lapsed}
    end
  end

  defp send_lapsed_to(meeting, recipient, job_id) do
    DeliveryClaims.once(job_id, "lapsed:" <> recipient.email, fn ->
      meeting
      |> Meetings.meeting_as_seen_by(recipient)
      |> Config.email_service_module().send_reschedule_request_lapsed()
      |> send_result("reschedule request lapsed", meeting)
    end)
  end

  defp send_result({:ok, _sent}, _email, _meeting), do: :ok

  defp send_result({:error, reason}, email, meeting) do
    Logger.error("Failed to send lapsed reschedule request email",
      email_action: email,
      meeting_id: meeting.id,
      error: LogFormat.reason(reason)
    )

    {:error, reason}
  end
end
