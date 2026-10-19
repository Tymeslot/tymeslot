defmodule Tymeslot.Meetings.CalendarEventSync do
  @moduledoc """
  Domain orchestration for synchronising meeting calendar events with the
  configured calendar provider (CalDAV, Google, Outlook).

  This module owns the *what* of calendar synchronisation — the create, update
  and delete flows, including:

  - the create→update fallback when a meeting already carries a provider mapping,
  - the update→create-on-404 recovery,
  - replacing an event an update cannot correct (`replace/3`),
  - persistence of the resulting calendar UID / provider event-id mapping back
    onto the meeting, and deletion of an event whose mapping cannot be kept
    (both in `Tymeslot.Meetings.CalendarEventMapping`),
  - sending an error notification to the calendar owner on persistent create
    failures, and on an update the provider can neither apply nor recover.

  Each entry point returns a tagged tuple that the calling Oban worker
  (`Tymeslot.Workers.CalendarEventWorker`) maps to a retry/error outcome:

    * `:ok`
    * `{:error, error_type}` — an error category the worker classifies for retry
    * `{:discard, reason}` — the operation can never succeed

  The worker owns the *when* (Oban dispatch, timeouts, backoff, retry
  classification); this module owns the *what*. Persistence always flows through
  the relevant query module — no raw `Repo.*` writes live here.
  """

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.CalendarEventCache
  alias Tymeslot.Meetings.CalendarEventMapping
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo
  require Logger

  @doc """
  Tells the owner a create was given up on after waiting out an unreachable or
  rate-limiting calendar, which `create/2` never reports itself. Sends nothing
  for a meeting that is gone, no longer expects an event, or has one already.
  """
  @spec notify_create_abandoned(term(), term()) :: :ok
  def notify_create_abandoned(meeting_id, reason) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        if MeetingState.expects_calendar_event?(meeting) and not calendar_mapping?(meeting),
          do: send_calendar_error_notification(meeting, reason)

        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Creates a calendar event for the given meeting.

  If the meeting already carries a provider event mapping (or an external UID
  from a legacy flow), this switches to an update so all fields stay in sync.

  The `attempt` count is used only to decide whether a persistent failure should
  trigger an owner notification.
  """
  @spec create(term(), pos_integer()) :: :ok | {:error, term()} | {:discard, term()}
  def create(meeting_id, attempt) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        ErrorTracking.put_context(user_id: meeting.organizer_user_id)

        # Another worker may already have created the event. OAuth providers
        # persist that mapping in provider_event_id; legacy flows may still
        # carry an external identifier in calendar_uid (copied from uid when
        # the column was added).
        if calendar_mapping?(meeting) do
          Logger.info("Meeting already has a calendar mapping, switching to update",
            meeting_id: meeting_id,
            provider_identifier: calendar_event_identifier(meeting)
          )

          update(meeting_id, attempt)
        else
          create_event_for_meeting(meeting, meeting_id, attempt)
        end

      {:error, :not_found} ->
        Logger.warning("Attempted to create calendar event for non-existent meeting",
          meeting_id: meeting_id
        )

        {:error, :meeting_not_found}
    end
  end

  @doc """
  Updates the calendar event for the given meeting, recreating it if the
  provider reports it no longer exists. Does nothing for a meeting that no
  longer expects an event.
  """
  @spec update(term(), pos_integer()) :: :ok | {:error, term()}
  def update(meeting_id, attempt) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        ErrorTracking.put_context(user_id: meeting.organizer_user_id)

        if MeetingState.expects_calendar_event?(meeting),
          do: update_event_for_meeting(meeting, meeting_id, attempt),
          else: skip_stale_update(meeting_id)

      {:error, :not_found} ->
        {:error, :meeting_not_found}
    end
  end

  # The meeting was cancelled, or its slot voided, after this update was
  # scheduled. Its event was deleted then, and an update recreates an event
  # it cannot find, which would put the meeting back on the calendar.
  defp skip_stale_update(meeting_id) do
    Logger.info("Meeting no longer expects a calendar event, skipping stale update",
      meeting_id: meeting_id
    )

    :ok
  end

  defp update_event_for_meeting(meeting, meeting_id, attempt) do
    Logger.info("Updating calendar event",
      meeting_id: meeting_id,
      provider_identifier: calendar_event_identifier(meeting)
    )

    event_data =
      CalendarEventBuilder.build_event_data(meeting,
        attendees: Meetings.attendees_for_calendar(meeting)
      )

    update_or_create_calendar_event(meeting, event_data, attempt)
  end

  @doc """
  Deletes the calendar event for the given meeting.

  Treats a missing meeting, a missing calendar integration, and an
  already-deleted remote event as success (idempotent deletion).
  """
  @spec delete(term(), pos_integer()) :: :ok | {:error, term()}
  def delete(meeting_id, _attempt) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, %{calendar_integration_id: nil} = meeting} ->
        ErrorTracking.put_context(user_id: meeting.organizer_user_id)

        Logger.info("No calendar integration linked, skipping calendar deletion",
          meeting_id: meeting_id
        )

        :ok

      {:ok, meeting} ->
        ErrorTracking.put_context(user_id: meeting.organizer_user_id)

        if MeetingState.expects_calendar_event?(meeting) do
          # The meeting has become live again since this deletion was
          # scheduled (e.g. the attendee rebooked after a reschedule
          # request). Deleting now would strip the event of a meeting that
          # currently expects one — skip and let the live state stand.
          Logger.info(
            "Meeting now expects a calendar event, skipping stale deletion",
            meeting_id: meeting_id
          )

          :ok
        else
          Logger.info("Deleting calendar event",
            meeting_id: meeting_id,
            provider_identifier: calendar_event_identifier(meeting)
          )

          delete_event_for_meeting(meeting, meeting_id)
        end

      {:error, :not_found} ->
        # Meeting doesn't exist, but deletion can still succeed
        Logger.info("Meeting not found but proceeding with calendar deletion",
          meeting_id: meeting_id
        )

        :ok
    end
  end

  @doc """
  Replaces the meeting's calendar event `event_id` with a new one written from
  the meeting as it now stands, then deletes the old one.

  For an event carrying something no update can take off it: a Microsoft
  Teams meeting attached to the booking's own Outlook event, which Graph keeps
  once `isOnlineMeeting` is set. A booking moved to another location would
  otherwise keep offering the Teams link from the organiser's calendar.

  The order is what keeps the booking alive. The new event is written and its
  id persisted before the old one is deleted, so by the time inbound sync
  hears of the deletion nothing links the old event to the meeting any more,
  and it is not read as the booking having been deleted externally
  (`Tymeslot.Meetings.ExternalCalendarChanges`). A retry after the new event
  was recorded finds the meeting no longer on `event_id` and only deletes it.

  Nothing is replaced when the meeting holds a room on `event_id` again (the
  booking moved back to Teams before this ran), which is an ordinary update,
  or when it no longer expects a calendar event, whose own delete job removes
  the event. Both are checked again under the meeting's row lock before the
  new event is recorded, since a room can be attached to `event_id` while the
  new event is being written; the new event is then deleted again.
  """
  @spec replace(term(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def replace(meeting_id, event_id, attempt) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        ErrorTracking.put_context(user_id: meeting.organizer_user_id)
        replace_event(meeting, event_id, attempt)

      {:error, :not_found} ->
        {:error, :meeting_not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal orchestration
  # ---------------------------------------------------------------------------

  defp replace_event(meeting, event_id, attempt) do
    case replacement_step(meeting, event_id) do
      :replace -> create_replacement(meeting, event_id, attempt)
      step -> run_replacement_step(step, meeting, event_id, attempt)
    end
  end

  # What replacing `event_id` still takes, judged from `meeting` as it stands.
  # Asked twice: on the meeting the job read, and again under the row lock
  # before the new event is recorded, since the video queue does not wait for
  # this one and can attach a room to `event_id` while the new event is being
  # written.
  defp replacement_step(%{video_room_id: event_id}, event_id), do: :update

  defp replacement_step(%{provider_event_id: event_id} = meeting, event_id) do
    if MeetingState.expects_calendar_event?(meeting), do: :replace, else: :skip
  end

  # Recorded on an earlier attempt: only the old event is left to delete.
  defp replacement_step(_meeting, _event_id), do: :delete

  defp run_replacement_step(:update, meeting, _event_id, attempt),
    do: update(meeting.id, attempt)

  defp run_replacement_step(:skip, meeting, _event_id, _attempt) do
    Logger.info("Meeting no longer expects a calendar event, skipping replacement",
      meeting_id: meeting.id
    )

    :ok
  end

  defp run_replacement_step(:delete, meeting, event_id, _attempt),
    do: delete_replaced_event(meeting, event_id)

  defp create_replacement(meeting, event_id, attempt) do
    Logger.info("Replacing calendar event", meeting_id: meeting.id)

    event_data =
      CalendarEventBuilder.build_event_data(meeting,
        attendees: Meetings.attendees_for_calendar(meeting)
      )

    with {:ok, created} <- CalendarEvents.create_event(event_data, meeting) do
      case record_replacement(meeting, event_id, created) do
        {:ok, :recorded} ->
          delete_replaced_event(meeting, event_id)

        # The meeting moved on while the new event was written, most often a
        # room attached to `event_id` meanwhile: the new event is not needed.
        {:ok, step} ->
          Logger.info("Meeting changed while its replacement event was written, deleting it",
            meeting_id: meeting.id
          )

          CalendarEventMapping.discard(meeting, created)
          run_replacement_step(step, meeting, event_id, attempt)

        {:error, reason} ->
          CalendarEventMapping.compensate_orphan(meeting, created)
          {:error, reason}
      end
    end
  end

  # The old id is cleared in the same write that records the new event, so
  # the meeting stops pointing at it whatever the new event is keyed by.
  defp record_replacement(meeting, event_id, created) do
    Repo.transaction(fn ->
      with {:ok, locked} <- MeetingQueries.get_meeting_for_update(meeting.id),
           :replace <- replacement_step(locked, event_id),
           :ok <- CalendarEventMapping.persist(locked, created, %{provider_event_id: nil}) do
        :recorded
      else
        {:error, :not_found} -> Repo.rollback(:meeting_not_found)
        {:error, reason} -> Repo.rollback(reason)
        step -> step
      end
    end)
  end

  # `meeting` still names the calendar the old event lives in. Once it is
  # gone, its cached copy goes too: nothing links it to the meeting now, so
  # until inbound sync drops it the grid would show it beside the booking.
  defp delete_replaced_event(meeting, event_id) do
    case CalendarEvents.delete_event(event_id, meeting) do
      result when result in [:ok, {:error, :not_found}] ->
        Logger.info("Replaced calendar event deleted", meeting_id: meeting.id)
        CalendarEventCache.forget(meeting, event_id)

      error ->
        error
    end
  end

  defp external_id?(nil), do: false

  defp external_id?(uid) do
    case UUID.cast(uid) do
      {:ok, _uuid} -> false
      :error -> true
    end
  end

  defp calendar_mapping?(meeting) do
    present_identifier?(meeting.provider_event_id) or external_id?(meeting.calendar_uid)
  end

  defp present_identifier?(identifier) when is_binary(identifier), do: byte_size(identifier) > 0
  defp present_identifier?(_identifier), do: false

  # Never `meeting.uid`: that is the booking's cancel/reschedule capability,
  # and whatever is returned here is sent to the provider and logged.
  defp calendar_event_identifier(meeting) do
    if present_identifier?(meeting.provider_event_id) do
      meeting.provider_event_id
    else
      meeting.calendar_uid
    end
  end

  defp update_or_create_calendar_event(meeting, event_data, attempt) do
    case update_existing_event(meeting, event_data) do
      {:error, :not_found} -> handle_missing_event(meeting.id, event_data, meeting, attempt)
      result -> result
    end
  end

  defp update_existing_event(meeting, event_data) do
    case CalendarEvents.update_event(calendar_event_identifier(meeting), event_data, meeting) do
      :ok ->
        record_successful_update(meeting, event_data)

      {:ok, _result} ->
        # Backward/forward compatibility if update returns tagged tuple
        record_successful_update(meeting, event_data)

      error ->
        error
    end
  end

  defp record_successful_update(meeting, event_data) do
    Logger.info("Calendar event updated successfully", meeting_id: meeting.id)
    CalendarEventCache.write_through_update(meeting, event_data)
    :ok
  end

  defp handle_missing_event(meeting_id, event_data, meeting, attempt) do
    Logger.info("Calendar event not found, creating new one", meeting_id: meeting_id)

    # Use the organizer_user_id to create in the correct calendar
    case CalendarEvents.create_event(event_data, meeting.organizer_user_id) do
      {:ok, created} ->
        CalendarEventMapping.persist_or_compensate(meeting, created)

      # The create's `If-None-Match: *` found an event at this UID after all:
      # between the update reporting it missing and this create, a concurrent
      # job for the same meeting wrote it. A booking whose video room arrives
      # quickly does exactly that, since the room enqueues this update while
      # the booking's own create is still in flight. The event exists now, so
      # the update that missed it can land. Retried once only: missing it a
      # second time is no longer that race.
      {:error, :precondition_failed} ->
        Logger.info("Calendar event appeared during recovery, retrying the update",
          meeting_id: meeting_id
        )

        retry_update_after_recovery(meeting, event_data, attempt)

      error ->
        error
    end
  end

  # The create has just proved the event exists, so an update that still
  # reports it missing is not the absence the worker may count as done: the
  # booking moved and its calendar event did not. It is returned as its own
  # error, so the job retries and the owner hears of it once retries run out,
  # rather than the job succeeding over an event left at the old time.
  defp retry_update_after_recovery(meeting, event_data, attempt) do
    case update_existing_event(meeting, event_data) do
      {:error, :not_found} ->
        Logger.error("Calendar event exists but cannot be updated",
          meeting_id: meeting.id
        )

        if attempt >= 5 do
          send_calendar_error_notification(meeting, :calendar_event_not_updatable)
        end

        {:error, :calendar_event_not_updatable}

      result ->
        result
    end
  end

  defp delete_event_for_meeting(meeting, meeting_id) do
    case CalendarEvents.delete_event(calendar_event_identifier(meeting), meeting) do
      :ok ->
        Logger.info("Calendar event deleted successfully", meeting_id: meeting_id)
        :ok

      {:error, :not_found} ->
        # Event already deleted, consider it success
        Logger.info("Calendar event already deleted", meeting_id: meeting_id)
        :ok

      error ->
        error
    end
  end

  defp create_event_for_meeting(meeting, meeting_id, attempt) do
    Logger.info("Creating calendar event", meeting_id: meeting_id)

    event_data =
      CalendarEventBuilder.build_event_data(meeting,
        attendees: Meetings.attendees_for_calendar(meeting)
      )

    # Use the meeting context to create in the correct calendar
    case CalendarEvents.create_event(event_data, meeting) do
      {:ok, created} ->
        Logger.info("Calendar event created successfully", meeting_id: meeting_id)

        CalendarEventMapping.persist_or_compensate(meeting, created)

      # `If-None-Match: *` found an event already at this meeting's own UID, so
      # it is this booking's event, written by a concurrent update job (see
      # `handle_missing_event/3`). Retrying the create can only fail the same
      # way, and on the last attempt would email the owner a sync error for an
      # event that exists. Update it instead, from a fresh read of the meeting:
      # this job's copy may predate the video link the other job carried.
      {:error, :precondition_failed} ->
        Logger.info("Calendar event already exists, switching to update",
          meeting_id: meeting_id
        )

        update(meeting_id, attempt)

      {:error, error_type} ->
        handle_create_event_error(error_type, meeting, meeting_id, attempt)
    end
  end

  # No calendar to write to is not a sync failure: the owner is never emailed
  # about it, and the worker ends the job without retrying.
  defp handle_create_event_error(error_type, meeting, meeting_id, attempt) do
    if CalendarEvents.no_calendar_error?(error_type),
      do: {:error, error_type},
      else: handle_sync_failure(error_type, meeting, meeting_id, attempt)
  end

  defp handle_sync_failure(error_type, meeting, meeting_id, attempt) do
    case error_type do
      # Waited out by the worker, which tells the owner itself if the wait
      # runs out on the last attempt (`notify_create_abandoned/2`).
      waiting when waiting in [:rate_limited, :circuit_open, :server_unresponsive] ->
        {:error, waiting}

      # A rate limit that named its wait (`OAuthBase`), waited out the same way.
      {:rate_limited, seconds} = waiting when is_integer(seconds) ->
        {:error, waiting}

      :unauthorized ->
        {:error, :unauthorized}

      {:connection_failed, _details} ->
        {:error, :connection_failed}

      reason ->
        Logger.error("Failed to create calendar event",
          meeting_id: meeting_id,
          reason: reason
        )

        # On final attempt, send error notification
        if attempt >= 5 do
          send_calendar_error_notification(meeting, reason)
        end

        # Return error to trigger retry
        {:error, reason}
    end
  end

  defp send_calendar_error_notification(meeting, error_reason) do
    Logger.info("Sending calendar sync error notification to owner",
      meeting_id: meeting.id,
      error: error_reason
    )

    # Send error notification email to calendar owner only
    # This helps identify persistent CalDAV issues
    case Config.email_service_module().send_calendar_sync_error(meeting, error_reason) do
      :ok ->
        :ok

      {:ok, _email} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send calendar sync error notification",
          meeting_id: meeting.id,
          error: LogFormat.reason(reason)
        )
    end
  end
end
