defmodule Tymeslot.Workers.VideoIntegrationDisconnectWorker do
  @moduledoc """
  Deletes the provider-side rooms belonging to a disconnected video integration,
  then removes the integration row.

  Deleting a room needs the integration's OAuth credentials, and those live on
  the row itself. The row is therefore soft-deleted when the user disconnects
  and hard-deleted here, once the work has drained: the alternative would be
  either blocking the request on a run of network calls or throwing the
  credentials away before they had been used.

  Only *upcoming* bookings are touched. Past bookings are history, and their
  provider rooms have usually expired on their own.

  This runs only when the user explicitly asked for the rooms to be deleted.
  Disconnecting on its own leaves them alone, because their join URLs are
  already sitting in attendees' calendar invites and deleting the room would
  break a meeting that is still going ahead.
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 5,
    priority: 2

  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Meetings.MeetingQueries

  require Logger

  @max_attempts 5

  @doc """
  Enqueues provider room cleanup for a soft-deleted integration.
  """
  @spec enqueue(pos_integer()) :: {:ok, atom()} | {:error, term()}
  def enqueue(integration_id) when is_integer(integration_id) do
    job_changeset =
      new(%{"integration_id" => integration_id},
        unique: [
          period: 3600,
          fields: [:args, :queue],
          keys: [:integration_id],
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
    # Matches VideoSyncWorker: 30s, 60s, 120s, then 180s.
    case attempt do
      1 -> 30
      2 -> 60
      3 -> 120
      _later -> 180
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => integration_id}, attempt: attempt} = job) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    case VideoIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        drain(integration, attempt)

      {:error, :not_found} ->
        {:discard, "Integration already removed"}

      {:error, :requires_reencryption, integration} ->
        # The stored credentials cannot be decrypted, so every provider call
        # would fail on authentication. Retrying is pointless; purge the row and
        # record that the rooms were left behind.
        Logger.error("Cannot decrypt credentials for room cleanup, purging integration",
          integration_id: integration.id,
          provider: integration.provider
        )

        purge(integration, 0, 0)
    end
  end

  defp drain(integration, attempt) do
    meetings =
      MeetingListQueries.list_upcoming_with_video_room_for_integration(
        integration.id,
        DateTime.utc_now()
      )

    failures = Enum.count(meetings, &(delete_room(integration, &1) == :error))

    finish(integration, attempt, length(meetings), failures)
  end

  defp finish(integration, _attempt, total, 0), do: purge(integration, total, 0)

  defp finish(integration, attempt, total, failures) when attempt >= @max_attempts do
    # Last attempt. Keeping the row would strand the user's OAuth credentials
    # indefinitely for the sake of rooms the provider is refusing to delete, so
    # the row goes and the orphans are recorded loudly instead.
    Logger.error("Giving up on provider room cleanup, purging integration anyway",
      integration_id: integration.id,
      provider: integration.provider,
      orphaned_rooms: failures
    )

    purge(integration, total, failures)
  end

  defp finish(integration, _attempt, _total, failures) do
    Logger.warning("Provider room cleanup incomplete, will retry",
      integration_id: integration.id,
      failed: failures
    )

    {:error, :room_cleanup_incomplete}
  end

  defp purge(integration, total, failures) do
    case VideoIntegrationQueries.delete(integration) do
      {:ok, _deleted} ->
        Logger.info("Video integration purged after room cleanup",
          integration_id: integration.id,
          rooms_deleted: total - failures,
          rooms_orphaned: failures
        )

        :ok

      {:error, changeset} ->
        Logger.warning("Failed to purge video integration after cleanup",
          integration_id: integration.id,
          errors: inspect(changeset.errors)
        )

        {:error, :purge_failed}
    end
  end

  defp delete_room(integration, meeting) do
    result =
      Video.delete_meeting_room(meeting.organizer_user_id,
        integration_id: integration.id,
        room_id: meeting.video_room_id
      )

    case result do
      :ok ->
        clear_room(meeting)

      {:error, :meeting_not_found} ->
        clear_room(meeting)

      {:error, reason} ->
        Logger.warning("Failed to delete provider room during disconnect",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :error
    end
  end

  # The room is gone on the provider, so the booking's join links are dead. They
  # are cleared rather than left pointing at nothing, and the calendar event is
  # refreshed so the attendee's invite stops advertising a URL that no longer
  # works.
  defp clear_room(meeting) do
    attrs = %{
      video_room_id: nil,
      video_room_enabled: false,
      organizer_video_url: nil,
      attendee_video_url: nil
    }

    case MeetingQueries.update_meeting(meeting, attrs) do
      {:ok, updated} ->
        schedule_calendar_update(updated)
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to clear video room after disconnect cleanup",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp schedule_calendar_update(meeting) do
    case CalendarEventScheduler.schedule_calendar_update(meeting.id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule calendar update after room removal",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end
end
