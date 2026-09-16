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

  ## Releasing a room the meeting no longer owns

  A reschedule that moves a meeting to a different location detaches its room
  in the same write that changes the location, so the meeting never advertises
  a join link for a place it is no longer held. The room still exists on the
  provider and nothing on the meeting points at it any more, so a `"release"`
  job (`release/1`) carries the room's identity in its own args instead of
  re-reading the meeting.

  That makes the job the room's only record. A cancelled meeting that could
  not reach its provider is retried nightly by
  `Tymeslot.Workers.OrphanedVideoRoomScanWorker`, because the meeting row still
  holds the room; a released room has no row to scan. So where a delete would
  discard an unreachable room, a release waits for the user to reconnect the
  provider instead, snoozing a day at a time for up to two weeks before it
  gives up loudly.
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 5,
    priority: 2

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.IntegrationResolver
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.VideoRoom.ErrorPolicy

  require Logger

  @unique_states [:available, :scheduled, :executing, :retryable]

  # How long a released room waits for an integration that can reach it.
  @release_snooze_seconds 86_400
  @release_max_snoozes 14

  @doc """
  Enqueues a video-room sync job for a meeting.

  `action` is `"update"` (reschedule) or `"delete"` (cancellation). Duplicate
  scheduling within the uniqueness window resolves to `{:ok, :already_scheduled}`.
  """
  @spec enqueue(String.t(), String.t()) :: {:ok, atom()} | {:error, term()}
  def enqueue(meeting_id, action) when is_binary(meeting_id) and action in ["update", "delete"] do
    insert(%{"meeting_id" => meeting_id, "action" => action}, [:meeting_id, :action])
  end

  @doc """
  Enqueues deletion of the provider room `meeting` holds, for a meeting that
  is about to stop holding it (see the module doc).

  Pass the meeting as it was *before* the room was detached: the room id, its
  provider, and the integration that created it are copied into the job, since
  the meeting will no longer carry them when the job runs. Keyed by room, so
  two rooms released from the same meeting in quick succession are both
  deleted.
  """
  @spec release(map()) :: {:ok, atom()} | {:error, term()}
  def release(%{id: meeting_id, video_room_id: room_id} = meeting)
      when is_binary(meeting_id) and is_binary(room_id) do
    insert(
      %{
        "action" => "release",
        "meeting_id" => meeting_id,
        "room_id" => room_id,
        "video_provider" => meeting.video_provider,
        "video_integration_id" => meeting.video_integration_id,
        "organizer_user_id" => meeting.organizer_user_id
      },
      [:room_id, :action]
    )
  end

  defp insert(args, unique_keys) do
    job_changeset =
      new(args,
        queue: :video_rooms,
        priority: 2,
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: unique_keys,
          states: @unique_states
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
  def perform(%Oban.Job{args: %{"action" => "release"} = args, attempt: attempt} = job) do
    Logger.metadata(job_id: job.id, attempt: attempt)
    room = released_room(args)

    case IntegrationResolver.resolve_for_meeting(room) do
      {:ok, integration_id} -> perform_action("release", room, integration_id, attempt)
      {:error, reason} -> await_reachable_integration(room, reason, job)
    end
  end

  def perform(%Oban.Job{args: args, attempt: attempt} = job) do
    %{"meeting_id" => meeting_id, "action" => action} = args
    Logger.metadata(job_id: job.id, attempt: attempt)

    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        dispatch(action, meeting, attempt)

      {:error, :not_found} ->
        Logger.info("Meeting gone before video sync, discarding", meeting_id: meeting_id)
        {:discard, "Meeting not found"}
    end
  end

  # Clause order matters: a meeting with no room at all is an ordinary no-op and
  # stays silent, whereas a meeting that holds a room nothing can reach is a
  # problem worth surfacing. Testing for the room first keeps the two apart.
  defp dispatch(_action, %{video_room_id: nil}, _attempt), do: discard_no_room()
  defp dispatch(_action, %{organizer_user_id: nil}, _attempt), do: discard_no_room()

  defp dispatch(action, meeting, attempt) do
    case IntegrationResolver.resolve_for_meeting(meeting) do
      {:ok, integration_id} -> perform_action(action, meeting, integration_id, attempt)
      {:error, reason} -> discard_unreachable(meeting, action, reason)
    end
  end

  defp perform_action("update", meeting, integration_id, attempt) do
    result =
      Video.update_meeting_room(meeting.organizer_user_id,
        integration_id: integration_id,
        room_id: meeting.video_room_id,
        topic: meeting.title,
        start_time: meeting.start_time,
        end_time: meeting.end_time
      )

    handle_result(result, "update", meeting, attempt)
  end

  defp perform_action("delete", meeting, integration_id, attempt) do
    result =
      Video.delete_meeting_room(meeting.organizer_user_id,
        integration_id: integration_id,
        room_id: meeting.video_room_id
      )

    handle_result(result, "delete", meeting, attempt)
  end

  # The same provider call as a delete, but nothing to clear afterwards: the
  # meeting let go of this room before the job was enqueued.
  defp perform_action("release", room, integration_id, attempt) do
    result =
      Video.delete_meeting_room(room.organizer_user_id,
        integration_id: integration_id,
        room_id: room.video_room_id
      )

    handle_result(result, "release", room, attempt)
  end

  defp discard_no_room, do: {:discard, "No provider video room to sync"}

  # The integration id captured at enqueue time is only a hint. The row can be
  # deleted while the job waits, and unlike a meeting's foreign key nothing
  # nils the copy in the args, so a stale id would pin every attempt to an
  # integration that no longer exists. Dropping it lets `IntegrationResolver`
  # fall back to whichever integration the user now holds for the provider.
  defp released_room(args) do
    user_id = args["organizer_user_id"]

    %{
      id: args["meeting_id"],
      video_room_id: args["room_id"],
      video_provider: args["video_provider"],
      organizer_user_id: user_id,
      video_integration_id: live_integration_id(args["video_integration_id"], user_id)
    }
  end

  defp live_integration_id(id, user_id) when is_integer(id) and is_integer(user_id) do
    case Video.fetch_integration_for_user(id, user_id) do
      {:ok, _integration} -> id
      {:error, :not_found} -> nil
    end
  end

  defp live_integration_id(_id, _user_id), do: nil

  defp await_reachable_integration(room, reason, job) do
    case SnoozePolicy.snooze_or_exhaust(SnoozePolicy.executions(job),
           max_snoozes: @release_max_snoozes,
           base_seconds: @release_snooze_seconds
         ) do
      {:snooze, _seconds} = snooze ->
        Logger.info("Released video room has no reachable integration yet, waiting",
          meeting_id: room.id,
          provider: room.video_provider,
          reason: reason
        )

        snooze

      :exhausted ->
        discard_unreachable(room, "release", reason)
    end
  end

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
  # Clearing the room id after a delete is what makes "cancelled and still
  # holding a room id" mean "cleanup has not happened yet", which
  # `Tymeslot.Workers.OrphanedVideoRoomScanWorker` relies on to converge instead
  # of re-deleting every cancelled meeting's room nightly.
  defp handle_result(:ok, "delete", meeting, _attempt), do: clear_video_room(meeting)

  defp handle_result(:ok, _action, _meeting, _attempt), do: :ok

  defp handle_result({:error, :meeting_not_found}, action, meeting, _attempt) do
    Logger.info("Provider video meeting already gone, treating as synced",
      meeting_id: meeting.id,
      action: action
    )

    if action == "delete", do: clear_video_room(meeting), else: :ok
  end

  # The integration's OAuth grant lacks the scope this action needs. Only the
  # user reconnecting can fix that, and the provider has already flagged the
  # integration for reauth, so retrying would just replay a guaranteed failure
  # until the job exhausts its attempts and pages an admin.
  defp handle_result({:error, :insufficient_scope}, action, meeting, _attempt) do
    Logger.error("Video provider scope insufficient, discarding job",
      meeting_id: meeting.id,
      action: action
    )

    {:discard, "Video provider scope insufficient — reconnect required"}
  end

  # The provider's circuit breaker is open: every attempt made before it
  # recovers is refused instantly. Snooze past the recovery window, the same
  # policy `VideoRoomWorker` already applies, rather than burning one of this
  # job's five attempts on a call known to be refused.
  defp handle_result({:error, :circuit_open}, _action, meeting, attempt) do
    ErrorPolicy.to_result(:circuit_open, attempt, meeting.video_provider)
  end

  defp handle_result({:error, reason}, action, meeting, _attempt) do
    Logger.warning("Provider video sync failed, will retry",
      meeting_id: meeting.id,
      action: action,
      reason: inspect(reason)
    )

    {:error, reason}
  end

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
