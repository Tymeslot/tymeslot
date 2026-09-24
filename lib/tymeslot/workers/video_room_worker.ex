defmodule Tymeslot.Workers.VideoRoomWorker do
  @moduledoc """
  Creates the video room for a confirmed meeting, in the background.

  Room creation is deliberately off the booking path: the booking is already
  confirmed by the time this runs, so a slow or failing video provider delays a
  join link rather than a booking. That trade makes the retry behaviour the
  interesting part of this worker, and it is split across two collaborators:

  - `Tymeslot.Workers.VideoRoom.ErrorPolicy` decides what a given failure means
    for the job: wait it out, or stop trying.
  - `Tymeslot.Workers.VideoRoom.Recovery` takes over once ordinary retries are
    spent, pacing the remaining attempts against the moment the attendees
    actually need the link and announcing the booking without one meanwhile.

  When the caller hands this job an announcement, it has deferred the whole
  event to it rather than only its emails, so that every notification carries
  the join link. This job is therefore what raises `meeting_created` for any
  booking with a video room, and `meeting_rescheduled` for a reschedule that
  moved a meeting onto one (`Tymeslot.Workers.VideoRoom.Announcement`).

  What is left here is the job itself: fetch the meeting, run the call under a
  timeout, and report the outcome.

  ## Waiting for the booking's calendar event

  A Teams meeting on the same Microsoft account as the booking's Outlook
  calendar is attached to the booking's own event, which the calendar job
  writes alongside this one. Until it exists, the job hands over to a fresh
  copy of itself a few seconds later rather than snoozing. A snooze counts as
  an execution, and `Recovery` measures executions: a wait of a dozen seconds
  would otherwise enter recovery and announce the booking without its link.
  The wait is bounded by the meeting, not the job:
  `Tymeslot.Integrations.MeetingProvisioning.teams_room_placement/1` stops
  asking for it two minutes after the booking, and the meeting gets a Teams
  event of its own instead.
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 10,
    # Highest priority: a booking is already confirmed and waiting on the link.
    priority: 0

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.{MeetingQueries, MeetingSchema}
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.VideoRoom.{Announcement, ErrorPolicy, Recovery}

  require Logger

  # What the provider call may spend beyond waiting on the provider itself:
  # reading and writing the meeting, and asking the circuit breaker.
  @local_work_margin_ms 10_000

  # How long a Teams meeting waits between looks for the booking's calendar
  # event; see "Waiting for the booking's calendar event" above.
  @calendar_event_wait_seconds 3

  @backoff_base_ms 1_000
  @backoff_cap_ms 16_000

  # Terminal failures that still owe the attendees a booking: there will never
  # be a link, so the announcement goes out now rather than after the attempts
  # are spent. Every terminal reason belongs here except `:meeting_not_found`,
  # where there is no booking left to announce.
  @announce_without_room [
    :video_integration_missing,
    :video_integration_inactive,
    :video_meeting_not_enabled,
    :invalid_configuration,
    :unauthorized
  ]

  # Deduplicate identical jobs within five minutes, so a retried booking step
  # cannot queue a second room creation for the same meeting. The reschedule
  # times are part of the key: two reschedules in quick succession owe two
  # announcements, and the window includes completed jobs, so without them the
  # second would be swallowed by the first and never sent at all.
  @unique [
    period: 300,
    fields: [:args, :queue],
    keys: [:meeting_id, :announce, :previous_start_time, :start_time]
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id} = args, attempt: attempt} = job) do
    announcement = Announcement.from_args(args)
    # Downstream specs take the id as a string, whatever the job args hold.
    meeting_id = to_string(meeting_id)

    # Recovery advances purely by snoozing, so what paces this job is how many
    # times it has run, not how many genuine attempts it has spent. The two are
    # the same number until a snooze happens; `SnoozePolicy.executions/1` keeps
    # them so across Oban 2.24, which stopped counting snoozes in `attempt`.
    execution = SnoozePolicy.executions(job)

    Logger.metadata(job_id: job.id, attempt: attempt, execution: execution)

    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        Logger.metadata(user_id: meeting.organizer_user_id)
        backoff(meeting_id, execution)

        Logger.info("Starting video room creation",
          meeting_id: meeting_id,
          announce: Announcement.owed?(announcement)
        )

        create_room(meeting, announcement, execution, args)

      {:error, :not_found} ->
        Logger.warning("Meeting not found, discarding video room job", meeting_id: meeting_id)
        {:discard, "Meeting not found"}
    end
  end

  @doc """
  Schedules video room creation for a meeting already announced without a room.
  """
  @spec schedule_video_room_creation(String.t()) :: :ok | {:error, String.t()}
  def schedule_video_room_creation(meeting_id), do: schedule(meeting_id, :none)

  @doc """
  Schedules video room creation, holding the booking's announcement until it
  finishes.

  `meeting.created` is raised once the room exists, or without a link if
  creation ultimately fails, so the attendees are never left without a
  confirmation and no subscriber loses the event.
  """
  @spec schedule_video_room_creation_with_announcement(String.t()) ::
          :ok | {:error, String.t()}
  def schedule_video_room_creation_with_announcement(meeting_id),
    do: schedule(meeting_id, :created)

  @doc """
  Schedules video room creation for a meeting a reschedule moved onto a video
  location, holding the reschedule's announcement until it finishes.

  `updated` and `original` are the meeting after and before the reschedule.
  `meeting.rescheduled` is raised once the room exists, or without a link if
  creation ultimately fails, and not at all if the meeting is rescheduled again
  first: that reschedule announces itself.
  """
  @spec schedule_video_room_creation_with_reschedule_announcement(
          MeetingSchema.t(),
          MeetingSchema.t()
        ) :: :ok | {:error, String.t()}
  def schedule_video_room_creation_with_reschedule_announcement(
        %MeetingSchema{} = updated,
        %MeetingSchema{} = original
      ),
      do: schedule(updated.id, Announcement.rescheduled(updated, original))

  defp schedule(meeting_id, announcement) do
    announcement
    |> Announcement.to_args()
    |> Map.put("meeting_id", meeting_id)
    |> new(queue: :video_rooms, priority: 0, unique: @unique)
    |> Oban.insert()
    |> handle_insert(meeting_id, announcement)
  end

  defp handle_insert({:ok, _job}, meeting_id, announcement) do
    Logger.info("Video room creation job scheduled",
      meeting_id: meeting_id,
      announce: Announcement.owed?(announcement)
    )

    :ok
  end

  # The uniqueness window did its job; the existing job will create the room.
  defp handle_insert({:error, %Changeset{errors: [unique: _details]}}, meeting_id, _announce) do
    Logger.info("Video room creation job already exists, skipping duplicate",
      meeting_id: meeting_id
    )

    :ok
  end

  defp handle_insert({:error, reason}, meeting_id, _announce) do
    Logger.error("Failed to schedule video room creation",
      meeting_id: meeting_id,
      error: format_insert_error(reason)
    )

    {:error, "Failed to schedule job"}
  end

  defp format_insert_error(%Changeset{} = changeset),
    do: Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

  defp format_insert_error(other), do: inspect(other)

  # Exponential backoff between ordinary retries: 1s, 2s, 4s, 8s, 16s. Sleeping
  # in the job rather than snoozing keeps the failure a genuine attempt, so it
  # is spent against `max_attempts` and the job cannot retry a broken provider
  # indefinitely.
  defp backoff(_meeting_id, 1), do: :ok

  defp backoff(meeting_id, execution) do
    if Application.get_env(:tymeslot, :test_mode, false) do
      :ok
    else
      backoff_ms = round(min(@backoff_base_ms * :math.pow(2, execution - 1), @backoff_cap_ms))

      Logger.info("Retrying video room creation after backoff",
        meeting_id: meeting_id,
        backoff_ms: backoff_ms
      )

      Process.sleep(backoff_ms)
    end
  end

  @doc """
  How long the job waits for room creation on `meeting`, in milliseconds.

  Longer than the network budget its video integration's provider declares,
  so the job only stops waiting on a call its own request timeouts have failed
  to end. Giving up any sooner would abandon a room the provider may already
  have created, and the retry would create another that no booking records.
  Waiting on the provider the meeting actually uses, rather than the slowest
  of all, keeps a slow provider from holding the queue for every other one.

  The meeting is read for those two fields alone, so a `MeetingSchema` and a
  bare map of them are both accepted. `%{a: t}` in a spec is a map with
  exactly that key, which a schema struct never is, hence the open map here.
  """
  @spec creation_timeout_ms(%{
          :organizer_user_id => pos_integer() | nil,
          :video_integration_id => pos_integer() | nil,
          optional(any()) => any()
        }) :: pos_integer()
  def creation_timeout_ms(meeting) do
    Video.room_creation_budget_ms(meeting.organizer_user_id, meeting.video_integration_id) +
      @local_work_margin_ms
  end

  # The provider call runs in a supervised task so a hung connection cannot pin
  # the queue's worker for longer than the timeout.
  defp create_room(meeting, announcement, execution, args) do
    meeting_id = meeting.id
    timeout_ms = creation_timeout_ms(meeting)

    task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        Meetings.add_video_room_to_meeting(meeting_id)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, meeting}} ->
        handle_success(meeting, announcement, execution)

      {:ok, {:error, :calendar_event_pending}} ->
        wait_for_calendar_event(meeting_id, args)

      {:ok, {:error, reason}} ->
        reason
        |> handle_failure(meeting_id, announcement, execution)
        |> to_oban_result(execution)

      {:ok, other} ->
        to_oban_result(other, execution)

      nil ->
        Logger.error("Video room creation timed out",
          meeting_id: meeting_id,
          timeout_ms: timeout_ms
        )

        handle_timeout(meeting_id, announcement, execution)
    end
  end

  # A fresh job starts its execution count again, which is the point. The
  # uniqueness window is deliberately not applied: it would match this job.
  defp wait_for_calendar_event(meeting_id, args) do
    case args
         |> new(queue: :video_rooms, priority: 0, schedule_in: @calendar_event_wait_seconds)
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule the wait for the booking's calendar event",
          meeting_id: meeting_id,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  # A room that arrives after recovery has already announced the meeting
  # without one must not announce it again; `Announcement.deliver/3` sees to
  # that.
  defp handle_success(meeting, announcement, execution) do
    Logger.info("Video room created successfully",
      meeting_id: Map.get(meeting, :id),
      room_ref: Redactor.fingerprint(Map.get(meeting, :video_room_id))
    )

    Announcement.deliver(
      announcement,
      meeting,
      Recovery.announced_without_room?(execution)
    )
  end

  defp handle_failure(reason, meeting_id, announcement, execution) do
    log_failure(reason, meeting_id)

    {:error, categorized} = ErrorPolicy.categorize(reason)

    cond do
      # No integration to call, or an account that cannot host a meeting, means
      # no amount of retrying will produce a link, so give up now and announce
      # the booking without one. Reaching `Recovery` instead would spend ten
      # attempts and a permanent-failure alert to arrive at the same place.
      categorized in @announce_without_room ->
        if Announcement.owed?(announcement),
          do: Recovery.send_fallback_notifications(meeting_id, announcement, execution)

        {:discard, ErrorPolicy.discard_reason(categorized)}

      Recovery.recovering?(execution, Announcement.owed?(announcement)) ->
        Recovery.enter(meeting_id, execution, "creation failed: #{inspect(reason)}", announcement)

      true ->
        {:error, categorized}
    end
  end

  defp log_failure(reason, meeting_id),
    do:
      Logger.error("Failed to create video room", meeting_id: meeting_id, reason: inspect(reason))

  defp handle_timeout(meeting_id, announcement, execution) do
    if Recovery.recovering?(execution, Announcement.owed?(announcement)) do
      Recovery.enter(meeting_id, execution, "creation timed out", announcement)
    else
      {:error, "Video room creation timed out"}
    end
  end

  defp to_oban_result(:ok, _execution), do: :ok
  defp to_oban_result({:snooze, _seconds} = snooze, _execution), do: snooze
  defp to_oban_result({:discard, _reason} = discard, _execution), do: discard
  defp to_oban_result({:error, reason}, execution), do: ErrorPolicy.to_result(reason, execution)

  defp to_oban_result(other, _execution) do
    Logger.error("Unexpected result from video room job", result: inspect(other))
    {:error, "Unexpected result"}
  end
end
