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
  alias Tymeslot.Workers.VideoRoom.ErrorPolicy

  require Logger

  @max_attempts 5

  # Matches `MeetingListQueries.list_upcoming_with_video_room_for_integration/3`'s
  # own default. Overridable at runtime (rather than a plain module attribute)
  # so tests can drive the full-page retry path without inserting hundreds of
  # meetings.
  @default_drain_page_limit 500

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
      {:ok, %{deleted_at: nil} = integration} ->
        # Reconnected since this job was enqueued (or since a previous
        # attempt), before any provider call has been made this attempt.
        # Draining now would delete a live integration's rooms out from under
        # the user, so the sweep stops here rather than at purge time.
        Logger.info("Video integration reconnected, skipping room cleanup",
          integration_id: integration.id
        )

        :ok

      {:ok, integration} ->
        drain(integration, attempt)

      {:error, :not_found} ->
        {:discard, "Integration already removed"}

      {:error, :requires_reencryption, %{deleted_at: nil} = integration} ->
        Logger.info("Video integration reconnected, skipping room cleanup",
          integration_id: integration.id
        )

        :ok

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
    limit = drain_page_limit()

    meetings =
      MeetingListQueries.list_upcoming_with_video_room_for_integration(
        integration.id,
        DateTime.utc_now(),
        limit
      )

    results = Enum.map(meetings, &delete_room(integration, &1))
    failures = Enum.count(results, &(&1 in [:error, :circuit_open]))

    cond do
      :circuit_open in results and attempt < @max_attempts ->
        # The provider's breaker is open: every remaining call in this batch
        # would fail instantly too. Snooze past the recovery window rather than
        # burning one of this job's attempts on calls known to be refused.
        # Past the last attempt this falls through instead, so an
        # indefinitely-open breaker cannot strand the row's OAuth credentials
        # forever the way an unconditional snooze would.
        ErrorPolicy.to_result(:circuit_open, attempt, integration.provider)

      length(meetings) == limit ->
        # A full page: more upcoming meetings on this integration than one
        # pass covers. `clear_room/1` removed every drained meeting from the
        # result set, so retrying re-queries the next page rather than
        # purging with the rest silently orphaned.
        Logger.warning("Video room drain page full, more meetings likely remain",
          integration_id: integration.id,
          drained_this_pass: length(meetings) - failures
        )

        {:error, :more_rooms_to_drain}

      true ->
        finish(integration, attempt, length(meetings), failures)
    end
  end

  defp drain_page_limit,
    do:
      Application.get_env(
        :tymeslot,
        :video_disconnect_drain_page_limit,
        @default_drain_page_limit
      )

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

  # `integration` was loaded at the start of this attempt, but `drain/2` in
  # between makes one network call per upcoming meeting — long enough for the
  # user to reconnect the same account, which reactivates this exact row
  # (`is_active: true, deleted_at: nil`, see
  # `VideoIntegrationSchema.clear_deleted_at_on_reactivation/1`). The
  # `deleted_at` guard therefore has to live in the delete statement itself
  # (`VideoIntegrationQueries.delete_if_still_deleted/1`), not in a read
  # beforehand: a reconnect landing between an application-level read and an
  # unconditional delete would still be destroyed by the delete.
  defp purge(integration, total, failures) do
    case VideoIntegrationQueries.delete_if_still_deleted(integration.id) do
      1 ->
        Logger.info("Video integration purged after room cleanup",
          integration_id: integration.id,
          rooms_deleted: total - failures,
          rooms_orphaned: failures
        )

        :ok

      0 ->
        Logger.info("Video integration reconnected before purge, skipping delete",
          integration_id: integration.id
        )

        :ok
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

      {:error, :circuit_open} ->
        :circuit_open

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
