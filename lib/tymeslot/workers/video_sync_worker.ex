defmodule Tymeslot.Workers.VideoSyncWorker do
  @moduledoc """
  Oban worker that syncs a meeting's provider-side video room (e.g. Zoom) after
  the booking changes.

  Reschedule and cancellation must update or delete the scheduled meeting on the
  video provider so its start time/duration stay in step with the booking and so
  cancelled meetings don't linger in the organiser's account. The provider call
  is a network request that can fail transiently (Zoom 5xx/429), so — like
  calendar sync — it runs here through Oban with retries rather than inline as a
  single best-effort attempt.

  Providers without a server-side meeting object (Google Meet, Teams, MiroTalk,
  Custom) resolve to `:ok` immediately, so enqueuing for them is a cheap no-op.

  The meeting is re-read on every attempt so the provider always receives the
  current times — never stale args captured at enqueue time. A meeting that no
  longer carries a video room (or vanished entirely) is treated as already
  synced and the job is discarded.

  The same sync serves the rooms of events created on the dashboard calendar
  grid, which no meeting holds. Those are recorded by
  `Tymeslot.CalendarGrid.EventVideoRooms` and enqueued with
  `enqueue_event_room/2`; a delete removes the record once the room is gone.
  Such a room's integration is resolved as a meeting's is, from its recorded
  provider when the link is gone. An `"expire"` job asks the calendar again
  whether the event is really over before deleting
  (`Tymeslot.CalendarGrid.check_event_video_room_expired/1`), since the event
  may have moved in between.
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 5,
    priority: 2

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.IntegrationResolver
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.VideoRoom.ErrorPolicy

  require Logger

  # A rate-limited sync snoozes on `ErrorPolicy`'s growing interval for this
  # many executions, about half an hour in all. A server still throttling after
  # that falls through to the ordinary retries, which end the job, so a server
  # that throttles for good cannot keep it snoozing for ever.
  @max_rate_limit_snoozes 10

  @doc """
  Enqueues a video-room sync job for a meeting.

  `action` is `"update"` (reschedule) or `"delete"` (cancellation, or a room
  that has outlived its meeting). Duplicate scheduling within the uniqueness
  window resolves to `{:ok, :already_scheduled}`.
  """
  @spec enqueue(String.t(), String.t()) :: {:ok, atom()} | {:error, term()}
  def enqueue(meeting_id, action) when is_binary(meeting_id) and action in ["update", "delete"],
    do: insert_job(%{"meeting_id" => meeting_id, "action" => action}, :meeting_id)

  @doc """
  Enqueues a video-room sync job for the room of a calendar grid event, by the
  id of its `Tymeslot.CalendarGrid.EventVideoRoomSchema` record.

  `action` is `"update"` (the event moved), `"delete"` (the event was
  deleted) or `"expire"` (the room seems to have outlived its event, which the
  job confirms before deleting it).
  """
  @spec enqueue_event_room(pos_integer(), String.t()) :: {:ok, atom()} | {:error, term()}
  def enqueue_event_room(room_id, action)
      when is_integer(room_id) and action in ["update", "delete", "expire"],
      do: insert_job(%{"event_room_id" => room_id, "action" => action}, :event_room_id)

  # Uniqueness keys on the record's own id: keyed on an absent `meeting_id`,
  # every event room's jobs for one action would count as duplicates.
  defp insert_job(args, id_key) do
    job_changeset =
      new(args,
        queue: :video_rooms,
        priority: 2,
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: [id_key, :action],
          states: [:available, :scheduled, :executing, :retryable]
        ]
      )

    case Oban.insert(job_changeset) do
      {:ok, %{conflict?: true}} -> {:ok, :already_scheduled}
      {:ok, _job} -> {:ok, :scheduled}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Progressive backoff: 30s, 60s, 120s, 180s, then 180s.
    case attempt do
      1 -> 30
      2 -> 60
      3 -> 120
      _later -> 180
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_room_id" => room_id, "action" => action}} = job) do
    executions = start_execution(job)

    case CalendarGrid.get_event_video_room(room_id) do
      {:ok, room} ->
        dispatch_event_room(action, room, executions)

      {:error, :not_found} ->
        Logger.info("Calendar event video room gone before video sync, discarding",
          calendar_event_video_room_id: room_id
        )

        {:discard, "Calendar event video room not found"}
    end
  end

  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id, "action" => action}} = job) do
    executions = start_execution(job)

    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        dispatch(action, meeting, executions)

      {:error, :not_found} ->
        Logger.info("Meeting gone before video sync, discarding", meeting_id: meeting_id)
        {:discard, "Meeting not found"}
    end
  end

  # Snoozes are paced and bounded by how many times the job has run, which
  # `job.attempt` stopped counting in Oban 2.24.
  defp start_execution(job) do
    executions = SnoozePolicy.executions(job)
    Logger.metadata(job_id: job.id, attempt: job.attempt, execution: executions)
    executions
  end

  # What syncing a room needs, whichever record holds it: a booking, or the
  # record of a calendar grid event's room.
  defp meeting_target(meeting),
    do: %{
      kind: :meeting,
      record: meeting,
      user_id: meeting.organizer_user_id,
      room_id: meeting.video_room_id,
      provider: meeting.video_provider,
      log: [meeting_id: meeting.id]
    }

  defp event_room_target(room),
    do: %{
      kind: :event_room,
      record: room,
      user_id: room.user_id,
      room_id: room.room_id,
      provider: room.provider,
      log: [calendar_event_video_room_id: room.id]
    }

  defp dispatch_event_room("expire", room, executions) do
    case CalendarGrid.confirm_event_video_room_expired(room) do
      :expired ->
        dispatch_event_room("delete", room, executions)

      :kept ->
        Logger.info("Calendar event still uses its video room, keeping it",
          calendar_event_video_room_id: room.id
        )

        :ok
    end
  end

  defp dispatch_event_room(action, room, executions) do
    resolvable = %{
      video_integration_id: room.video_integration_id,
      organizer_user_id: room.user_id,
      video_provider: room.provider
    }

    case IntegrationResolver.resolve_for_meeting(resolvable) do
      {:ok, integration_id} ->
        perform_action(action, event_room_target(room), integration_id, executions)

      {:error, reason} ->
        Logger.warning(
          "Calendar event holds a provider video room but no video integration can reach it",
          calendar_event_video_room_id: room.id,
          action: action,
          provider: room.provider,
          reason: reason
        )

        {:discard, "No video integration can reach the provider room"}
    end
  end

  # Clause order matters: a meeting with no room at all is an ordinary no-op and
  # stays silent, whereas a meeting that holds a room nothing can reach is a
  # problem worth surfacing. Testing for the room first keeps the two apart.
  defp dispatch(_action, %{video_room_id: nil}, _executions), do: discard_no_room()
  defp dispatch(_action, %{organizer_user_id: nil}, _executions), do: discard_no_room()

  defp dispatch(action, meeting, executions) do
    case IntegrationResolver.resolve_for_meeting(meeting) do
      {:ok, integration_id} ->
        perform_action(action, meeting_target(meeting), integration_id, executions)

      {:error, reason} ->
        discard_unreachable(meeting, action, reason)
    end
  end

  defp perform_action("update", target, integration_id, executions) do
    result =
      Video.update_meeting_room(
        target.user_id,
        [integration_id: integration_id, room_id: target.room_id] ++ room_changes(target)
      )

    handle_result(result, "update", target, executions)
  end

  defp perform_action("delete", target, integration_id, executions) do
    result =
      Video.delete_meeting_room(target.user_id,
        integration_id: integration_id,
        room_id: target.room_id
      )

    handle_result(result, "delete", target, executions)
  end

  defp room_changes(%{kind: :meeting, record: meeting}),
    do: [
      # The name the room was created with, so a reschedule renames it to the
      # same value creation would have used.
      topic: EventDetails.from_meeting(meeting).summary,
      start_time: meeting.start_time,
      end_time: meeting.end_time
    ]

  # A grid event's room keeps its name: only the lobby follows the event.
  defp room_changes(%{kind: :event_room, record: room}),
    do: [start_time: room.lobby_opens_at, end_time: room.ends_at]

  defp discard_no_room, do: {:discard, "No provider video room to sync"}

  # The meeting holds a live provider room but nothing can authenticate against
  # it: the integration was disconnected and never replaced, or the row predates
  # `meetings.video_provider`. Retrying cannot help — only the user reconnecting
  # can — so the job is discarded, but loudly. A silent :ok here is exactly what
  # let orphaned Zoom meetings accumulate unnoticed.
  defp discard_unreachable(meeting, action, reason) do
    Logger.warning(
      "Meeting holds a provider video room but no video integration can reach it",
      meeting_id: meeting.id,
      action: action,
      provider: meeting.video_provider,
      video_room_id: meeting.video_room_id,
      reason: reason
    )

    {:discard, "No video integration can reach the provider room"}
  end

  # The provider treats a missing remote meeting as success, so :ok and the
  # idempotent not-found cases both arrive here as :ok. Anything else is a
  # genuine failure worth retrying via Oban's backoff.
  #
  # Clearing the room id after a delete is what makes "still holding a room id"
  # mean "cleanup has not happened yet", which both
  # `Tymeslot.Workers.OrphanedVideoRoomScanWorker` (cancelled meetings) and
  # `Tymeslot.Workers.ExpiredVideoRoomCleanupWorker` (meetings that ended a while
  # ago) rely on to converge instead of re-deleting the same rooms nightly.
  defp handle_result(:ok, "delete", target, _executions), do: clear_room(target)

  defp handle_result(:ok, _action, _target, _executions), do: :ok

  defp handle_result({:error, :meeting_not_found}, action, target, _executions) do
    Logger.info(
      "Provider video meeting already gone, treating as synced",
      target.log ++ [action: action]
    )

    if action == "delete", do: clear_room(target), else: :ok
  end

  # The integration's OAuth grant lacks the scope this action needs. Only the
  # user reconnecting can fix that, and the provider has already flagged the
  # integration for reauth, so retrying would just replay a guaranteed failure
  # until the job exhausts its attempts and pages an admin.
  defp handle_result({:error, :insufficient_scope}, action, target, _executions) do
    Logger.error(
      "Video provider scope insufficient, discarding job",
      target.log ++ [action: action]
    )

    {:discard, "Video provider scope insufficient — reconnect required"}
  end

  # The provider refused the stored credentials and has flagged the integration
  # for reconnection. Retrying would replay a guaranteed refusal, and on a
  # self-hosted server such as Nextcloud each refusal also counts against the
  # server's brute-force protection for Tymeslot's address.
  defp handle_result({:error, :unauthorized}, action, target, _executions) do
    Logger.error(
      "Video provider refused the stored credentials, discarding job",
      target.log ++ [action: action]
    )

    {:discard, "Video provider refused the stored credentials: reconnect required"}
  end

  # The provider refused the change for a reason that repeats on every attempt,
  # such as a server that redirects or an account no longer allowed to change
  # the room. `ErrorPolicy` holds the same verdict for room creation.
  defp handle_result(
         {:error, {:configuration_error, _details} = reason},
         action,
         target,
         _executions
       ) do
    Logger.error(
      "Video provider refused the change for good, discarding job",
      target.log ++ [action: action, reason: inspect(reason)]
    )

    {:error, categorized} = ErrorPolicy.categorize(reason)
    {:discard, ErrorPolicy.discard_reason(categorized)}
  end

  # The provider is throttling Tymeslot. Retrying at once would only extend the
  # throttle, so the job snoozes on the growing interval room creation uses,
  # which costs no attempt, until the snooze budget is spent.
  defp handle_result({:error, :rate_limited}, _action, _target, executions)
       when executions < @max_rate_limit_snoozes do
    ErrorPolicy.to_result(:rate_limited, executions)
  end

  # The provider's circuit breaker is open: every attempt made before it
  # recovers is refused instantly. Snooze past the recovery window, the same
  # policy `VideoRoomWorker` already applies, rather than burning one of this
  # job's five attempts on a call known to be refused.
  defp handle_result({:error, :circuit_open}, _action, target, executions) do
    ErrorPolicy.to_result(:circuit_open, executions, target.provider)
  end

  defp handle_result({:error, reason}, action, target, _executions) do
    Logger.warning(
      "Provider video sync failed, will retry",
      target.log ++ [action: action, reason: inspect(reason)]
    )

    {:error, reason}
  end

  defp clear_room(%{kind: :meeting, record: meeting}), do: clear_video_room(meeting)

  # A grid event's room exists only as this record, so once the room is gone
  # the record goes too, and nothing scans for it again.
  defp clear_room(%{kind: :event_room, record: room}),
    do: CalendarGrid.forget_event_video_room(room)

  defp clear_video_room(meeting) do
    case MeetingQueries.update_meeting(meeting, %{
           video_room_id: nil,
           video_room_enabled: false
         }) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        # The provider room is gone either way, so the job has done its work.
        # Only the local marker is stale, and the orphan scan will retry it
        # harmlessly.
        Logger.warning("Failed to clear video room marker after provider delete",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end
end
