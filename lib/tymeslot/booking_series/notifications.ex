defmodule Tymeslot.BookingSeries.Notifications do
  @moduledoc """
  The emails a booking series sends as one, rather than per session.

  A series is confirmed once, for all its sessions: each session is
  announced without emails of its own (`Tymeslot.Bookings.Activation`,
  `announce: :series`) and keeps its own reminders. The confirmation waits
  for the sessions' video rooms, so that it carries every join link
  (`Tymeslot.Workers.SeriesAnnouncementWorker`), then goes to the booker and
  the organiser (`Tymeslot.Notifications.Email.SeriesEmails`).

  The host's automations hear of the series with its confirmation, in one
  `meeting.series_created`, and of a series request, in one
  `meeting.series_requested` (`Tymeslot.BookingSeries.Automation`).

  Several sessions cancelled at once are likewise told in one email to each
  (`schedule_series_cancellation/3`).

  A series held for the host's approval is requested once, for all its
  sessions (`schedule_series_request/1`): one request to the host, one
  acknowledgement to the booker, and one expiry job at the deadline the
  sessions share. Its answer is one email too: the series confirmation once
  approved, and the booker's `schedule_series_request_outcome/2` once
  declined or expired (`Tymeslot.BookingSeries.Approval`).

  A session of its own changed later (rescheduled, cancelled) sends the
  ordinary email for that one meeting or seat, as any booking does.
  """

  require Logger

  alias Tymeslot.BookingSeries.Automation
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings.ApprovalJobs
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Repo
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
  Schedules the one request a series held for approval sends its host and
  booker, the one reminder its host gets halfway to the deadline if the
  request is still open then, and the one job that releases the series at
  its deadline
  (`Tymeslot.Meetings.ApprovalJobs`, on the first session still held: every
  session shares its deadline, and expiring one expires the series). Called
  in the transaction that holds the series for approval, booking or payment,
  so it commits with it or not at all.

  No session schedules a request, nudge or expiry of its own
  (`Tymeslot.Bookings.Activation`, `announce: :series`), and the request and
  its nudge are scheduled once per series ever.
  """
  @spec schedule_series_request(SeriesSchema.t()) :: {:ok, :scheduled} | {:error, term()}
  def schedule_series_request(%SeriesSchema{} = series) do
    held =
      series
      |> SeriesQueries.list_meetings()
      |> Enum.filter(&MeetingState.awaiting_approval?/1)

    first_held = List.first(held)

    with :ok <- EmailScheduler.schedule_series_request_emails(series.id),
         :ok <- schedule_series_nudge(series, first_held),
         :ok <- announce_series_request(series, held) do
      schedule_series_expiry(first_held)
      {:ok, :scheduled}
    end
  end

  # One `meeting.series_requested` for the host's automations, in place of
  # a `meeting.requested` for each session.
  defp announce_series_request(_series, []), do: :ok

  defp announce_series_request(series, held) do
    case Oban.insert(Automation.requested_job(series, Enum.map(held, & &1.id))) do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The expiry sweep backstops a lost job, as for a single request.
  defp schedule_series_expiry(nil), do: :ok

  defp schedule_series_expiry(%Meeting{} = first_held),
    do: ApprovalJobs.schedule_expiry(first_held)

  # Halfway through the shared window, as for a single request, once per
  # series.
  defp schedule_series_nudge(_series, nil), do: :ok

  defp schedule_series_nudge(series, %Meeting{} = first_held) do
    case ApprovalJobs.nudge_at(first_held) do
      nil -> :ok
      send_at -> EmailScheduler.schedule_series_request_nudge(series.id, send_at)
    end
  end

  @doc """
  Schedules the booker's one email saying their series request was
  declined or expired. The host, who declined it or let it lapse, is sent
  nothing, as for a single request.
  """
  @spec schedule_series_request_outcome(SeriesSchema.t(), :declined | :expired) ::
          :ok | {:error, term()}
  def schedule_series_request_outcome(%SeriesSchema{id: series_id}, variant)
      when variant in [:declined, :expired],
      do: EmailScheduler.schedule_series_request_outcome(series_id, variant)

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

  # The automations hear of the series with its emails, in one step: both
  # are unique per series while Oban keeps them, so a confirmation run again
  # announces nothing twice (`Tymeslot.BookingSeries.Automation`).
  defp queue_confirmation(series) do
    queued =
      Repo.transaction(fn ->
        with :ok <- EmailScheduler.schedule_series_confirmation_emails(series.id),
             {:ok, _job} <- Oban.insert(Automation.created_job(series)) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case queued do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

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
  The sessions of `series` still booked (`live?/1`), in series order.
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

  @doc """
  Whether a session of a series is still booked: a meeting not cancelled or
  waiting for a new time, or a seat not given up in such a meeting.
  """
  @spec live?(occurrence()) :: boolean()
  def live?(%Meeting{} = meeting), do: MeetingState.expects_calendar_event?(meeting)

  def live?(%Participant{meeting: meeting} = seat),
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
