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
  provider rooms have usually expired on their own. The exception is a provider
  whose rooms stay on the organiser's server until something deletes them
  (`ProviderConfig.rooms_deleted_after_meeting/0`): every room such an
  integration still holds is deleted, ended and cancelled meetings included,
  because once the row is purged nothing has the credentials to reach them.
  `Tymeslot.Integrations.Video.disconnect_room_scope/1` makes that choice, for
  the disconnect modal's count as much as for this drain.

  The rooms drained are those of bookings and those made for events on the
  dashboard calendar grid, whose records (`Tymeslot.CalendarGrid.EventVideoRooms`)
  are removed as their rooms go.

  This runs only when the user explicitly asked for the rooms to be deleted.
  Disconnecting on its own leaves them alone, because their join URLs are
  already sitting in attendees' calendar invites and deleting the room would
  break a meeting that is still going ahead.
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 5,
    priority: 2

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.VideoRoom.ErrorPolicy
  alias Tymeslot.Workers.VideoSyncWorker

  require Logger

  @max_attempts 5

  # Pages one run drains before yielding the queue with a snooze. A full page
  # that made progress is not a failure, so it neither errors nor spends an
  # attempt; the snooze after this many pages counts towards `@max_attempts`
  # like any other execution. 10 pages of 500 rooms, over at most 5
  # executions, cover 25,000 rooms, against the few thousand upcoming bookings
  # (or, for a provider whose rooms outlive their meeting, all-time rooms) a
  # heavy integration holds.
  @max_pages_per_run 10

  # How long a run that used up its pages waits before the next: only long
  # enough to yield the queue.
  @next_run_snooze_seconds 5

  # Overridable at runtime (rather than a plain module attribute) so tests can
  # drive the full-page retry path without inserting hundreds of meetings.
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

  @behaviour ExpectedJobOutcome

  # Another path removed the integration first: nothing is left to do.
  @already_removed "Integration already removed"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do: reason in [@already_removed]

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

    # The circuit-open branch below advances this job by snoozing, so its
    # budget has to count snoozes too: from Oban 2.24 `attempt` alone stops
    # moving, and an indefinitely-open breaker would snooze forever rather
    # than falling through to the purge that stops the credentials being
    # stranded.
    executions = SnoozePolicy.executions(job)

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
        drain(integration, executions)

      {:error, :not_found} ->
        {:discard, @already_removed}

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

  defp drain(integration, executions), do: drain_page(integration, executions, 1, 0)

  # One page of rooms. `drained` counts the rooms deleted on earlier pages of
  # this run, for the purge's log line.
  defp drain_page(integration, executions, page, drained) do
    limit = drain_page_limit()

    {meetings, event_rooms} = rooms_to_drain(integration, limit)

    results =
      Enum.map(meetings, &delete_meeting_room(integration, &1)) ++
        Enum.map(event_rooms, &delete_event_room(integration, &1))

    failures = Enum.count(results, &(&1 in [:error, :circuit_open]))
    total = drained + length(results)
    full_page? = length(meetings) == limit or length(event_rooms) == limit
    # Failed rooms stay listed, so a full page that deleted nothing would
    # list the same rooms again.
    progress? = failures < length(results)

    cond do
      :circuit_open in results and executions < @max_attempts ->
        # The provider's breaker is open: every remaining call in this batch
        # would fail instantly too. Snooze past the recovery window rather than
        # burning one of this job's attempts on calls known to be refused.
        # Past the last attempt this falls through instead, so an
        # indefinitely-open breaker cannot strand the row's OAuth credentials
        # forever the way an unconditional snooze would.
        ErrorPolicy.to_result(:circuit_open, executions, integration.provider)

      full_page? and progress? and page < @max_pages_per_run ->
        # More rooms on this integration than one page covers. Clearing a room
        # removed every drained meeting from the result set, so the next query
        # returns the next page rather than the same one.
        drain_page(integration, executions, page + 1, total - failures)

      full_page? and progress? and executions < @max_attempts ->
        Logger.info("Video room drain continues in the next run",
          integration_id: integration.id,
          drained_this_run: total - failures
        )

        {:snooze, @next_run_snooze_seconds}

      full_page? and progress? ->
        # Out of runs with rooms still listed. Purge as on the last attempt
        # rather than strand the credentials.
        give_up(integration, total, failures, more_may_remain: true)

      true ->
        finish(integration, executions, total, failures, full_page?)
    end
  end

  defp rooms_to_drain(integration, limit) do
    scope = Video.disconnect_room_scope(integration.provider)
    now = DateTime.utc_now()

    {MeetingListQueries.list_with_video_room_for_integration(integration.id, scope, now, limit),
     CalendarGrid.list_event_video_rooms_for_integration(integration.id, scope, now, limit)}
  end

  defp drain_page_limit,
    do:
      Application.get_env(
        :tymeslot,
        :video_disconnect_drain_page_limit,
        @default_drain_page_limit
      )

  defp finish(integration, _executions, total, 0, _full_page?), do: purge(integration, total, 0)

  # A full page of refused deletes hides whatever lies past it: the same rooms
  # come back first every time, so the rest were never tried.
  defp finish(integration, executions, total, failures, full_page?)
       when executions >= @max_attempts,
       do: give_up(integration, total, failures, more_may_remain: full_page?)

  defp finish(integration, _executions, _total, failures, _full_page?) do
    Logger.warning("Provider room cleanup incomplete, will retry",
      integration_id: integration.id,
      failed: failures
    )

    {:error, :room_cleanup_incomplete}
  end

  # Last attempt, or last run with rooms still listed. Keeping the row would
  # strand the user's OAuth credentials indefinitely for the sake of rooms the
  # provider is refusing to delete (or that one more run might reach), so the
  # row goes and the orphans are recorded loudly instead.
  defp give_up(integration, total, failures, more_may_remain: more_may_remain) do
    Logger.error("Giving up on provider room cleanup, purging integration anyway",
      integration_id: integration.id,
      provider: integration.provider,
      orphaned_rooms: failures,
      more_rooms_may_remain: more_may_remain
    )

    purge(integration, total, failures)
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

  # A room that is the booking's own calendar event (a Teams meeting on the
  # same Microsoft account) is not the provider's to delete: deleting it would
  # take the booking off the organiser's calendar and mail attendees a
  # cancellation. It is released the way a location change releases it
  # (`VideoSyncWorker.release/1`), which has calendar sync replace the event
  # with one carrying no online meeting. Only upcoming bookings reach this, as
  # Teams rooms are drained in the `:upcoming` scope, so no past event is
  # rewritten. The room is cleared in the same transaction that schedules the
  # replacement: the replacement is skipped for a meeting still holding a room
  # on the event, and a cleared room is never listed for another pass.
  defp delete_meeting_room(
         _integration,
         %{video_room_id: event_id, provider_event_id: event_id} = meeting
       ) do
    case Repo.transaction(fn -> release_attached_room(meeting) end) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to release attached video room during disconnect",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :error
    end
  end

  defp delete_meeting_room(integration, meeting),
    do:
      delete_room(integration, meeting.organizer_user_id, meeting.video_room_id,
        log: [meeting_id: meeting.id],
        on_deleted: fn -> Meetings.forget_video_room(meeting) end
      )

  defp release_attached_room(meeting) do
    with {:ok, _updated} <- Meetings.clear_video_room(meeting),
         {:ok, _scheduled} <- VideoSyncWorker.release(meeting) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A grid event's room exists only as its record, so the record goes with it.
  defp delete_event_room(integration, room),
    do:
      delete_room(integration, room.user_id, room.room_id,
        log: [calendar_event_video_room_id: room.id],
        on_deleted: fn -> CalendarGrid.forget_event_video_room(room) end
      )

  defp delete_room(integration, user_id, room_id, opts) do
    result =
      Video.delete_meeting_room(user_id, integration_id: integration.id, room_id: room_id)

    case result do
      :ok ->
        opts[:on_deleted].()

      {:error, :circuit_open} ->
        :circuit_open

      {:error, reason} ->
        Logger.warning(
          "Failed to delete provider room during disconnect",
          opts[:log] ++ [reason: LogFormat.reason(reason)]
        )

        :error
    end
  end
end
