defmodule Tymeslot.BookingSeries.Notifications do
  @moduledoc """
  The emails a booking series sends as one, rather than per session.

  A series is confirmed once, for all its sessions: each session is
  announced without emails of its own (`Tymeslot.Bookings.Activation`,
  `announce: :series`) and keeps its own reminders. The confirmation waits
  for the sessions' video rooms, so that it carries every join link
  (`Tymeslot.Workers.SeriesAnnouncementWorker`), then goes to the booker and
  the organiser (`Tymeslot.Notifications.Email.SeriesEmails`).

  Several sessions cancelled at once are likewise told in one email to each
  (`schedule_series_cancellation/3`).

  A session of its own changed later (rescheduled, cancelled) sends the
  ordinary email for that one meeting or seat, as any booking does.
  """

  require Logger

  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Workers.SeriesAnnouncementWorker
  alias Tymeslot.Workers.VideoRoomWorker

  # How long the confirmation waits before looking at the rooms again.
  @room_wait_seconds 30

  @type occurrence :: Meeting.t() | Participant.t()

  @doc """
  Schedules the one confirmation a newly booked series sends its booker and
  host. Called in the transaction that books the series, so it commits with
  the series or not at all; a paid or approval series calls it where its
  sessions are confirmed, inside a transaction or not.

  One job per series: a second call while the first is still to run
  returns that job.
  """
  @spec schedule_series_confirmation(SeriesSchema.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_series_confirmation(%SeriesSchema{id: series_id}) do
    %{"series_id" => series_id}
    |> SeriesAnnouncementWorker.new()
    |> Oban.insert()
  end

  @doc """
  Queues the series confirmation emails, once the sessions' video rooms are
  ready: `{:snooze, seconds}` while a session's room is still being made.

  With `stop_waiting: true` (the worker has waited long enough) it queues
  them anyway; a session without its link says the link will be in its
  reminder.

  Sends nothing, and returns `:ok`, when the series has been cancelled or
  none of its sessions is still booked.
  """
  @spec send_series_confirmation(SeriesSchema.t(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:error, term()}
  def send_series_confirmation(series, opts \\ [])

  def send_series_confirmation(%SeriesSchema{cancelled_at: %DateTime{}} = series, _opts) do
    Logger.info("Series cancelled before its confirmation, sending none", series_id: series.id)
    :ok
  end

  def send_series_confirmation(%SeriesSchema{} = series, opts) do
    case live_occurrences(series) do
      [] ->
        Logger.info("No session of the series is still booked, sending no confirmation",
          series_id: series.id
        )

        :ok

      live ->
        live
        |> Enum.count(&room_pending?/1)
        |> confirm_or_wait(series, Keyword.get(opts, :stop_waiting, false))
    end
  end

  defp confirm_or_wait(0, series, _stop_waiting), do: queue_confirmation(series)

  defp confirm_or_wait(pending, series, true) do
    Logger.warning("Sending the series confirmation without every video room",
      series_id: series.id,
      rooms_pending: pending
    )

    queue_confirmation(series)
  end

  defp confirm_or_wait(_pending, _series, false), do: {:snooze, @room_wait_seconds}

  defp queue_confirmation(series),
    do: EmailScheduler.schedule_series_confirmation_emails(series.id)

  @doc """
  Schedules one email to the booker and one to the organiser listing the
  `cancelled` sessions of `series` (its meetings, or its seats on a group
  type), worded for whoever cancelled them. Called once the sessions are
  cancelled, in the same transaction.
  """
  @spec schedule_series_cancellation(
          SeriesSchema.t(),
          [occurrence(), ...],
          :attendee | :organizer
        ) ::
          {:ok, term()} | {:error, term()}
  def schedule_series_cancellation(%SeriesSchema{} = series, [_first | _rest] = cancelled, by)
      when by in [:attendee, :organizer] do
    EmailScheduler.schedule_series_cancellation_emails(
      series.id,
      Enum.map(cancelled, & &1.id),
      by
    )
  end

  @doc """
  The sessions of `series` still booked, in series order: a meeting not
  cancelled or waiting for a new time, or a seat not given up in such a
  meeting.
  """
  @spec live_occurrences(SeriesSchema.t()) :: [occurrence()]
  def live_occurrences(%SeriesSchema{} = series) do
    series
    |> SeriesQueries.list_occurrences()
    |> Enum.filter(&live?/1)
  end

  @doc """
  The sessions of `series` among `ids` (meeting or seat ids) that are
  cancelled, in series order.
  """
  @spec cancelled_occurrences(SeriesSchema.t(), [binary()]) :: [occurrence()]
  def cancelled_occurrences(%SeriesSchema{} = series, ids) when is_list(ids) do
    series
    |> SeriesQueries.list_occurrences()
    |> Enum.filter(&(&1.id in ids and cancelled?(&1)))
  end

  defp live?(%Meeting{} = meeting), do: MeetingState.expects_calendar_event?(meeting)

  defp live?(%Participant{meeting: meeting} = seat),
    do: Participant.live?(seat) and MeetingState.expects_calendar_event?(meeting)

  defp cancelled?(%Meeting{} = meeting), do: MeetingState.cancelled?(meeting)

  defp cancelled?(%Participant{meeting: meeting} = seat),
    do: not Participant.live?(seat) or MeetingState.cancelled?(meeting)

  # The room is wanted (the session has a video integration), not made yet
  # (`VideoRoomWorker` writes `video_room_id` when it is) and still being
  # made: its job has not finished. A job that gave up, or never ran, will
  # not make one, so there is nothing to wait for.
  defp room_pending?(%Participant{meeting: meeting}), do: room_pending?(meeting)
  defp room_pending?(%Meeting{video_integration_id: nil}), do: false

  defp room_pending?(%Meeting{video_room_id: nil} = meeting),
    do: Jobs.pending_meeting_job?(VideoRoomWorker, meeting.id)

  defp room_pending?(%Meeting{}), do: false
end
