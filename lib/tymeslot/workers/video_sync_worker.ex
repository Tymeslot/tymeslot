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
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 5,
    priority: 2

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings.MeetingQueries

  require Logger

  @doc """
  Enqueues a video-room sync job for a meeting.

  `action` is `"update"` (reschedule) or `"delete"` (cancellation). Duplicate
  scheduling within the uniqueness window resolves to `{:ok, :already_scheduled}`.
  """
  @spec enqueue(String.t(), String.t()) :: {:ok, atom()} | {:error, term()}
  def enqueue(meeting_id, action) when is_binary(meeting_id) and action in ["update", "delete"] do
    job_changeset =
      new(%{"meeting_id" => meeting_id, "action" => action},
        queue: :video_rooms,
        priority: 2,
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: [:meeting_id, :action],
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
  def perform(%Oban.Job{args: args, attempt: attempt} = job) do
    %{"meeting_id" => meeting_id, "action" => action} = args
    Logger.metadata(job_id: job.id, attempt: attempt)

    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        dispatch(action, meeting)

      {:error, :not_found} ->
        Logger.info("Meeting gone before video sync, discarding", meeting_id: meeting_id)
        {:discard, "Meeting not found"}
    end
  end

  defp dispatch(_action, %{video_integration_id: nil}), do: discard_no_room()
  defp dispatch(_action, %{video_room_id: nil}), do: discard_no_room()
  defp dispatch(_action, %{organizer_user_id: nil}), do: discard_no_room()

  defp dispatch("update", meeting) do
    result =
      Video.update_meeting_room(meeting.organizer_user_id,
        integration_id: meeting.video_integration_id,
        room_id: meeting.video_room_id,
        topic: meeting.title,
        start_time: meeting.start_time,
        end_time: meeting.end_time
      )

    handle_result(result, "update", meeting)
  end

  defp dispatch("delete", meeting) do
    result =
      Video.delete_meeting_room(meeting.organizer_user_id,
        integration_id: meeting.video_integration_id,
        room_id: meeting.video_room_id
      )

    handle_result(result, "delete", meeting)
  end

  defp discard_no_room, do: {:discard, "No provider video room to sync"}

  # The provider treats a missing remote meeting as success, so :ok and the
  # idempotent not-found cases both arrive here as :ok. Anything else is a
  # genuine failure worth retrying via Oban's backoff.
  defp handle_result(:ok, _action, _meeting), do: :ok

  defp handle_result({:error, :meeting_not_found}, action, meeting) do
    Logger.info("Provider video meeting already gone, treating as synced",
      meeting_id: meeting.id,
      action: action
    )

    :ok
  end

  defp handle_result({:error, reason}, action, meeting) do
    Logger.warning("Provider video sync failed, will retry",
      meeting_id: meeting.id,
      action: action,
      reason: inspect(reason)
    )

    {:error, reason}
  end
end
