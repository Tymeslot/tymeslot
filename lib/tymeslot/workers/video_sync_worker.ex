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

  Providers without a server-side meeting object (Google Meet, MiroTalk,
  Custom) resolve to `:ok` immediately, so enqueuing for them is a cheap no-op.
  So does a Teams meeting attached to the booking's own calendar event, which
  calendar sync keeps in step instead.

  The meeting is re-read on every attempt so the provider always receives the
  current times — never stale args captured at enqueue time. A meeting that no
  longer carries a video room (or vanished entirely) is treated as already
  synced and the job is discarded.

  The same sync serves the rooms of events created on the dashboard calendar
  grid, which no meeting holds. Those are recorded by
  `Tymeslot.CalendarGrid.EventVideoRooms` and enqueued with
  `enqueue_event_room/2`; a delete removes the record once the room is gone.
  Such a room's integration is resolved as a meeting's is, from its recorded
  provider when the link is gone. An `"expire"` or `"orphan"` job first asks
  the calendar whether the event is really over, or gone: it may have moved.

  A room no record holds at all is deleted by its provider id through
  `enqueue_room_delete/3`: the Zoom meeting a calendar grid event's video
  change replaced, or one whose grid event was deleted.

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

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
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

  # How long a released room waits for an integration that can reach it.
  @release_snooze_seconds 86_400
  @release_max_snoozes 14

  # The actions that delete the provider room.
  @removals ["delete", "release"]

  @doc """
  Enqueues a video-room sync job for a meeting.

  `action` is `"update"` (reschedule) or `"delete"` (cancellation, or a room
  that has outlived its meeting). Duplicate scheduling within the uniqueness
  window resolves to `{:ok, :already_scheduled}`.
  """
  @spec enqueue(String.t(), String.t()) :: {:ok, atom()} | {:error, term()}
  def enqueue(meeting_id, action) when is_binary(meeting_id) and action in ["update", "delete"],
    do: insert_job(%{"meeting_id" => meeting_id, "action" => action}, [:meeting_id, :action])

  @doc """
  Enqueues a video-room sync job for the room of a calendar grid event, by the
  id of its `Tymeslot.CalendarGrid.EventVideoRoomSchema` record.

  `action` is `"update"` (the event moved), `"delete"` (the event was
  deleted), `"expire"` (the room seems to have outlived its event) or
  `"orphan"` (the event seems deleted in a calendar client); the job confirms
  either before deleting the room.
  """
  @spec enqueue_event_room(pos_integer(), String.t()) :: {:ok, atom()} | {:error, term()}
  def enqueue_event_room(room_id, action)
      when is_integer(room_id) and action in ["update", "delete", "expire", "orphan"],
      do: insert_job(%{"event_room_id" => room_id, "action" => action}, [:event_room_id, :action])

  @doc """
  Enqueues the delete of a room no record holds, by the id its provider knows
  it by, on the video integration `video_integration_id` of `user_id`.

  For a calendar grid event's room that `Tymeslot.CalendarGrid.EventVideoRooms`
  does not record, whose id was parsed exactly out of its join link (a Zoom
  meeting's). A provider that no longer has the room counts as done, and so
  does an integration that has gone, since nothing can reach the room then.
  """
  @spec enqueue_room_delete(pos_integer(), pos_integer(), String.t()) ::
          {:ok, atom()} | {:error, term()}
  def enqueue_room_delete(user_id, video_integration_id, room_id)
      when is_integer(user_id) and is_integer(video_integration_id) and is_binary(room_id) and
             room_id != "" do
    insert_job(
      %{
        "user_id" => user_id,
        "video_integration_id" => video_integration_id,
        "room_id" => room_id,
        "action" => "delete"
      },
      [:video_integration_id, :room_id, :action]
    )
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
  def release(meeting)

  # A room that is the booking's own calendar event (a Teams meeting on the
  # same Microsoft account) is not the provider's to delete: deleting it would
  # delete the booking's event, which calendar sync still owns. Graph keeps the
  # online meeting on that event for good once set, so the only way to take
  # the join link off it is a new event, and that is calendar sync's job. It
  # runs in the calendar queue, one write per meeting at a time, so it cannot
  # race the update the same location change enqueued there. The video queue
  # does not wait for it, though: a later move back to Teams can attach a
  # room to the event while it is being replaced. Both sides re-check the
  # meeting under its row lock before recording anything
  # (`Tymeslot.Meetings.CalendarEventSync.replace/3`,
  # `Tymeslot.Meetings.VideoRoomAttachment.persist/2`), so whichever records
  # first, the other gives way.
  def release(%{id: meeting_id, video_room_id: event_id, provider_event_id: event_id})
      when is_binary(meeting_id) and is_binary(event_id) do
    case CalendarEventScheduler.schedule_calendar_replacement(meeting_id, event_id) do
      {:ok, _job} -> {:ok, :calendar_event}
      {:error, reason} -> {:error, reason}
    end
  end

  def release(%{id: meeting_id, video_room_id: room_id} = meeting)
      when is_binary(meeting_id) and is_binary(room_id) do
    insert_job(
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

  # Uniqueness keys on the id of whatever the job acts on: keyed on an absent
  # `meeting_id`, every event room's jobs for one action would count as
  # duplicates, a released room is keyed by the room itself, and a room
  # deleted by its provider id by that id and its integration.
  defp insert_job(args, unique_keys) do
    job_changeset =
      new(args,
        queue: :video_rooms,
        priority: 2,
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: unique_keys,
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
  # Matched first: a release job also carries the `meeting_id` it came from.
  def perform(%Oban.Job{args: %{"action" => "release"} = args} = job) do
    executions = start_execution(job)
    target = released_target(args)

    case IntegrationResolver.resolve_for_meeting(released_resolvable(args)) do
      {:ok, integration_id} -> perform_action("release", target, integration_id, executions)
      {:error, reason} -> await_reachable_integration(target, reason, executions)
    end
  end

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

  def perform(
        %Oban.Job{
          args: %{
            "user_id" => user_id,
            "video_integration_id" => video_integration_id,
            "room_id" => room_id,
            "action" => "delete"
          }
        } = job
      ) do
    executions = start_execution(job)

    case Video.fetch_integration_for_user(video_integration_id, user_id) do
      {:ok, integration} ->
        target = %{
          kind: :room,
          record: nil,
          user_id: user_id,
          room_id: room_id,
          provider: integration.provider,
          log: [
            video_integration_id: video_integration_id,
            room_ref: Redactor.fingerprint(room_id)
          ]
        }

        perform_action("delete", target, video_integration_id, executions)

      {:error, :not_found} ->
        Logger.info("Video integration gone before a room delete, discarding",
          video_integration_id: video_integration_id,
          room_ref: Redactor.fingerprint(room_id)
        )

        {:discard, "Video integration not found"}
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

  # A released room is held by nothing but the job's args: the meeting it
  # came from let go of it before the job was enqueued.
  defp released_target(args),
    do: %{
      kind: :released,
      record: nil,
      user_id: args["organizer_user_id"],
      room_id: args["room_id"],
      provider: args["video_provider"],
      log: [meeting_id: args["meeting_id"]]
    }

  # The integration id captured at enqueue time is only a hint. The row can be
  # deleted while the job waits, and unlike a meeting's foreign key nothing
  # nils the copy in the args, so a stale id would pin every attempt to an
  # integration that no longer exists. Dropping it lets `IntegrationResolver`
  # fall back to whichever integration the user now holds for the provider.
  defp released_resolvable(args) do
    user_id = args["organizer_user_id"]

    %{
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

  defp await_reachable_integration(target, reason, executions) do
    case SnoozePolicy.snooze_or_exhaust(executions,
           max_snoozes: @release_max_snoozes,
           base_seconds: @release_snooze_seconds
         ) do
      {:snooze, _seconds} = snooze ->
        Logger.info(
          "Released video room has no reachable integration yet, waiting",
          target.log ++ [provider: target.provider, reason: reason]
        )

        snooze

      :exhausted ->
        discard_unreachable(target, "release", reason)
    end
  end

  defp dispatch_event_room(action, room, executions) when action in ["expire", "orphan"] do
    confirmed =
      if action == "expire",
        do: CalendarGrid.confirm_event_video_room_expired(room),
        else: CalendarGrid.confirm_event_video_room_gone(room)

    if confirmed == :kept do
      Logger.info("Calendar event still uses its video room, keeping it",
        calendar_event_video_room_id: room.id
      )
    else
      dispatch_event_room("delete", room, executions)
    end
  end

  # A grid event's own calendar event (an attached Teams meeting) is never
  # recorded; should one be, it goes with the event, as a booking's does.
  defp dispatch_event_room(action, %{room_id: id, provider_event_id: id} = room, executions),
    do: handle_result(:ok, action, event_room_target(room), executions)

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

  # A room that is the booking's own calendar event moves and goes with that
  # event, through calendar sync. Updating it here would race the calendar's
  # own write, and deleting it would delete the booking's event, so the
  # provider is left alone and only the local record converges.
  defp dispatch(
         action,
         %{video_room_id: event_id, provider_event_id: event_id} = meeting,
         executions
       ),
       do: handle_result(:ok, action, meeting_target(meeting), executions)

  defp dispatch(action, meeting, executions) do
    case IntegrationResolver.resolve_for_meeting(meeting) do
      {:ok, integration_id} ->
        perform_action(action, meeting_target(meeting), integration_id, executions)

      {:error, reason} ->
        discard_unreachable(meeting_target(meeting), action, reason)
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

  # A release is the same provider call as a delete; only what happens to the
  # local record afterwards differs (see `clear_room/1`).
  defp perform_action(action, target, integration_id, executions) when action in @removals do
    result =
      Video.delete_meeting_room(target.user_id,
        integration_id: integration_id,
        room_id: target.room_id
      )

    handle_result(result, action, target, executions)
  end

  defp room_changes(%{kind: :meeting, record: meeting}),
    do: [
      # The name the room was created with, so a reschedule renames it to the
      # same value creation would have used.
      topic: EventDetails.from_meeting(meeting).summary,
      start_time: meeting.start_time,
      end_time: meeting.end_time
    ]

  # A grid event's room keeps its name: only its timing follows the event. For
  # Talk that is the lobby; a separate Teams event records the event's own
  # start as its lobby time, so the event itself moves.
  defp room_changes(%{kind: :event_room, record: room}),
    do: [start_time: room.lobby_opens_at, end_time: room.ends_at]

  defp discard_no_room, do: {:discard, "No provider video room to sync"}

  # The meeting holds a live provider room but nothing can authenticate against
  # it: the integration was disconnected and never replaced, or the row predates
  # `meetings.video_provider`. Retrying cannot help — only the user reconnecting
  # can — so the job is discarded, but loudly. A silent :ok here is exactly what
  # let orphaned Zoom meetings accumulate unnoticed. A released room reaches
  # this only once it has waited out its snoozes.
  #
  # Only a fingerprint of the room id goes into the line: the id is the join
  # link for every link-based provider, and `meeting_id` already leads to the
  # row that holds the real one (or, for a release, to the meeting that did).
  defp discard_unreachable(target, action, reason) do
    Logger.warning(
      "Meeting holds a provider video room but no video integration can reach it",
      target.log ++
        [
          action: action,
          provider: target.provider,
          room_ref: Redactor.fingerprint(target.room_id),
          reason: reason
        ]
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
  defp handle_result(:ok, action, target, _executions) when action in @removals,
    do: clear_room(target)

  defp handle_result(:ok, _action, _target, _executions), do: :ok

  defp handle_result({:error, :meeting_not_found}, action, target, _executions) do
    Logger.info(
      "Provider video meeting already gone, treating as synced",
      target.log ++ [action: action]
    )

    if action in @removals, do: clear_room(target), else: :ok
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

  # A room no record holds: once it is gone there is nothing left to clear.
  defp clear_room(%{kind: :room}), do: :ok

  # A grid event's room exists only as this record, so once the room is gone
  # the record goes too, and nothing scans for it again.
  defp clear_room(%{kind: :event_room, record: room}),
    do: CalendarGrid.forget_event_video_room(room)

  # The meeting let go of a released room before the job was enqueued, so
  # there is nothing left to clear.
  defp clear_room(%{kind: :released}), do: :ok

  # The room is gone on the provider, so the booking's join links are dead and
  # go with it, as `Tymeslot.Workers.VideoIntegrationDisconnectWorker` already
  # does for the same reason. A cancellation used to clear the room id alone and
  # leave `organizer_video_url` and `attendee_video_url` pointing at a
  # conversation nobody can join, for every reader that keeps showing them.
  defp clear_video_room(meeting) do
    case MeetingQueries.update_meeting(meeting, %{
           video_room_id: nil,
           video_room_enabled: false,
           organizer_video_url: nil,
           attendee_video_url: nil
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
