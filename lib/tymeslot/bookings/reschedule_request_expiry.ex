defmodule Tymeslot.Bookings.RescheduleRequestExpiry do
  @moduledoc """
  Ends a host's reschedule request the attendee never answered.

  A request (`Tymeslot.Bookings.RescheduleRequest`) voids the meeting's slot
  and waits on the attendee to pick a new time. It stays answerable until
  `Tymeslot.Meetings.MeetingState.reschedule_request_deadline/1`, the later of
  the original start and a fixed window after it was sent; from then on
  `Tymeslot.Bookings.Policy` refuses an answer, and the host's cancellation,
  even before anything here has run.

  At the deadline `expire/1` moves the meeting to `:expired`, the same
  terminal status a booking request nobody answered ends in, rather than
  `:cancelled`: nobody cancelled it, and the cancellation pipeline (its
  emails, its `meeting.cancelled` webhook) would describe something that did
  not happen. Both sides are told by email, the calendar and video room are
  released as for any other ended meeting, and nothing is refunded
  automatically: the attendee had a confirmed booking, so any payment is left
  for the host to refund from their payments screen, where an expired
  meeting's payment is listed as outstanding.

  Two paths reach `expire/1`: the job `schedule/1` queues for the deadline
  when the request is made, and `Tymeslot.Bookings.Workers.RescheduleRequestSweepWorker`,
  which catches requests whose job was lost or which were open before the
  job existed. The transition is guarded, so they may overlap.
  """

  require Logger

  alias Tymeslot.Bookings.Workers.RescheduleRequestExpiryWorker
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.CommittedStep
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @doc """
  Queues the job that expires `meeting`'s request at its deadline. Meant to
  run in the request's own transaction, so a request is never left without
  one. A meeting with no request stamped on it has nothing to schedule.
  """
  @spec schedule(MeetingSchema.t()) :: :ok | {:error, term()}
  def schedule(%MeetingSchema{reschedule_requested_at: %DateTime{} = requested_at} = meeting) do
    job =
      RescheduleRequestExpiryWorker.new(
        %{"meeting_id" => meeting.id, "requested_at" => DateTime.to_iso8601(requested_at)},
        scheduled_at: MeetingState.reschedule_request_deadline(meeting)
      )

    case Oban.insert(job) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def schedule(%MeetingSchema{}), do: :ok

  @doc """
  Expires `meeting`'s reschedule request if it is still open and its
  deadline has been reached, and tells the host and the attendee.

  `{:error, :not_lapsed}` when the row no longer qualifies: the attendee
  picked a new time, the meeting ended some other way, or the deadline is
  still ahead. Nothing is sent then.
  """
  @spec expire(MeetingSchema.t()) :: {:ok, MeetingSchema.t()} | {:error, :not_lapsed | term()}
  def expire(%MeetingSchema{reschedule_requested_at: %DateTime{} = requested_at} = meeting) do
    result =
      Repo.transaction(fn ->
        with {:ok, expired} <-
               MeetingTransitionQueries.expire_reschedule_request(
                 meeting.id,
                 requested_at,
                 Clock.utc_now()
               ),
             :ok <- EmailScheduler.schedule_reschedule_request_lapsed(expired.id) do
          expired
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, expired} ->
        Logger.info("Reschedule request lapsed unanswered", meeting_id: expired.id)
        release(expired)
        {:ok, expired}

      {:error, :not_lapsed} = not_lapsed ->
        not_lapsed

      {:error, reason} = error ->
        Logger.error("Failed to expire reschedule request",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  def expire(%MeetingSchema{}), do: {:error, :not_lapsed}

  # The request already scheduled the calendar event's deletion; asking again
  # covers one that failed, as every other way a meeting ends does. The video
  # room was kept for the new time the attendee never picked.
  defp release(meeting) do
    CommittedStep.run(meeting, "cancel calendar event", fn ->
      Meetings.cancel_calendar_event(meeting)
    end)

    CommittedStep.run(meeting, "release video room", fn -> release_video_room(meeting) end)
    :ok
  end

  defp release_video_room(%MeetingSchema{video_room_id: nil}), do: :ok
  defp release_video_room(%MeetingSchema{organizer_user_id: nil}), do: :ok

  defp release_video_room(meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "delete") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue video room deletion for a lapsed reschedule request",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
