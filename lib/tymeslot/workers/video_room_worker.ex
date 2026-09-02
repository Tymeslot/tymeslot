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

  When the caller asks for `announce`, it has deferred the whole
  `meeting_created` event to this job rather than only its emails, so that every
  notification carries the join link. This job is therefore what raises that
  event for any booking with a video room.

  What is left here is the job itself: fetch the meeting, run the call under a
  timeout, and report the outcome.
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 10,
    # Highest priority: a booking is already confirmed and waiting on the link.
    priority: 0

  alias Ecto.Changeset
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.VideoRoom.{ErrorPolicy, Recovery}

  require Logger

  @video_api_timeout_ms 20_000
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
  # cannot queue a second room creation for the same meeting.
  @unique [period: 300, fields: [:args, :queue], keys: [:meeting_id, :announce]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id} = args, attempt: attempt} = job) do
    announce = announce?(args)
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
          announce: announce
        )

        create_room(meeting_id, announce, execution)

      {:error, :not_found} ->
        Logger.warning("Meeting not found, discarding video room job", meeting_id: meeting_id)
        {:discard, "Meeting not found"}
    end
  end

  @doc """
  Schedules video room creation for a meeting already announced without a room.
  """
  @spec schedule_video_room_creation(String.t()) :: :ok | {:error, String.t()}
  def schedule_video_room_creation(meeting_id), do: schedule(meeting_id, false)

  @doc """
  Schedules video room creation, holding the booking's announcement until it
  finishes.

  `meeting.created` is raised once the room exists, or without a link if
  creation ultimately fails, so the attendees are never left without a
  confirmation and no subscriber loses the event.
  """
  @spec schedule_video_room_creation_with_announcement(String.t()) ::
          :ok | {:error, String.t()}
  def schedule_video_room_creation_with_announcement(meeting_id), do: schedule(meeting_id, true)

  defp announce?(%{"announce" => announce}), do: announce
  defp announce?(_args), do: false

  defp schedule(meeting_id, announce) do
    %{"meeting_id" => meeting_id, "announce" => announce}
    |> new(queue: :video_rooms, priority: 0, unique: @unique)
    |> Oban.insert()
    |> handle_insert(meeting_id, announce)
  end

  defp handle_insert({:ok, _job}, meeting_id, announce) do
    Logger.info("Video room creation job scheduled",
      meeting_id: meeting_id,
      announce: announce
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

  # The provider call runs in a supervised task so a hung connection cannot pin
  # the queue's worker for longer than the timeout.
  defp create_room(meeting_id, announce, execution) do
    task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        Meetings.add_video_room_to_meeting(meeting_id)
      end)

    case Task.yield(task, @video_api_timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, meeting}} ->
        handle_success(meeting, announce)

      {:ok, {:error, reason}} ->
        reason
        |> handle_failure(meeting_id, announce, execution)
        |> to_oban_result(execution)

      {:ok, other} ->
        to_oban_result(other, execution)

      nil ->
        Logger.error("Video room creation timed out",
          meeting_id: meeting_id,
          timeout_ms: @video_api_timeout_ms
        )

        handle_timeout(meeting_id, announce, execution)
    end
  end

  defp handle_success(meeting, announce) do
    Logger.info("Video room created successfully",
      meeting_id: Map.get(meeting, :id),
      room_id: Map.get(meeting, :video_room_id)
    )

    # A room that arrives after recovery has already announced the booking
    # without one must not announce it again; `meeting_created/1` claims the
    # event once per meeting, so this call is a no-op in that case.
    if announce and Map.get(meeting, :id) do
      Logger.info("Announcing the meeting now its room exists", meeting_id: meeting.id)
      Events.meeting_created(meeting)
    end

    :ok
  end

  defp handle_failure(reason, meeting_id, announce, execution) do
    Logger.error("Failed to create video room", meeting_id: meeting_id, reason: inspect(reason))

    {:error, categorized} = ErrorPolicy.categorize(reason)

    cond do
      # No integration to call, or an account that cannot host a meeting, means
      # no amount of retrying will produce a link, so give up now and announce
      # the booking without one. Reaching `Recovery` instead would spend ten
      # attempts and a permanent-failure alert to arrive at the same place.
      categorized in @announce_without_room ->
        if announce, do: Recovery.send_fallback_notifications(meeting_id)
        {:discard, ErrorPolicy.discard_reason(categorized)}

      Recovery.recovering?(execution, announce) ->
        Recovery.enter(meeting_id, execution, "creation failed: #{inspect(reason)}")

      true ->
        {:error, categorized}
    end
  end

  defp handle_timeout(meeting_id, announce, execution) do
    if Recovery.recovering?(execution, announce) do
      Recovery.enter(meeting_id, execution, "creation timed out")
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
