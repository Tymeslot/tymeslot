defmodule Tymeslot.Meetings.CalendarEventSync do
  @moduledoc """
  Domain orchestration for synchronising meeting calendar events with the
  configured calendar provider (CalDAV, Google, Outlook).

  This module owns the *what* of calendar synchronisation — the create, update
  and delete flows, including:

  - the create→update fallback when a meeting already carries a provider mapping,
  - the update→create-on-404 recovery,
  - replacing an event an update cannot correct (`replace/3`),
  - persistence of the resulting provider UID / event-id mapping back onto the
    meeting (via `Tymeslot.Meetings.MeetingQueries`),
  - sending an error notification to the calendar owner on persistent create
    failures.

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
  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.CalendarEventCache
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo
  require Logger

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
        Logger.metadata(user_id: meeting.organizer_user_id)

        # Another worker may already have created the event. OAuth providers
        # persist that mapping in provider_event_id; legacy flows may still
        # carry an external identifier in uid.
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
  provider reports it no longer exists.
  """
  @spec update(term(), pos_integer()) :: :ok | {:error, term()}
  def update(meeting_id, _attempt) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        Logger.metadata(user_id: meeting.organizer_user_id)

        Logger.info("Updating calendar event",
          meeting_id: meeting_id,
          provider_identifier: calendar_event_identifier(meeting)
        )

        event_data = CalendarEventBuilder.build_event_data(meeting)
        update_or_create_calendar_event(meeting, event_data)

      {:error, :not_found} ->
        {:error, :meeting_not_found}
    end
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
        Logger.metadata(user_id: meeting.organizer_user_id)

        Logger.info("No calendar integration linked, skipping calendar deletion",
          meeting_id: meeting_id
        )

        :ok

      {:ok, meeting} ->
        Logger.metadata(user_id: meeting.organizer_user_id)

        if MeetingState.expects_calendar_event?(meeting) do
          # The meeting has become live again since this deletion was
          # scheduled (e.g. the attendee rebooked after a reschedule
          # request). Deleting now would strip the event of a meeting that
          # currently expects one — skip and let the live state stand.
          Logger.info(
            "Meeting now expects a calendar event, skipping stale deletion",
            meeting_id: meeting_id,
            uid: meeting.uid
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
        Logger.metadata(user_id: meeting.organizer_user_id)
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

    event_data = CalendarEventBuilder.build_event_data(meeting)

    with {:ok, created} <- calendar_module().create_event(event_data, meeting) do
      case record_replacement(meeting, event_id, created) do
        {:ok, :recorded} ->
          delete_replaced_event(meeting, event_id)

        # The meeting moved on while the new event was written, most often a
        # room attached to `event_id` meanwhile: the new event is not needed.
        {:ok, step} ->
          Logger.info("Meeting changed while its replacement event was written, deleting it",
            meeting_id: meeting.id
          )

          discard_created_event(meeting, created)
          run_replacement_step(step, meeting, event_id, attempt)

        {:error, reason} ->
          compensate_orphaned_event(meeting, created)
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
           :ok <- persist_calendar_mapping(locked, created, %{provider_event_id: nil}) do
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
    case calendar_module().delete_event(event_id, meeting) do
      result when result in [:ok, {:ok, :deleted}, {:error, :not_found}] ->
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
    present_identifier?(meeting.provider_event_id) or external_id?(meeting.uid)
  end

  defp present_identifier?(identifier) when is_binary(identifier), do: byte_size(identifier) > 0
  defp present_identifier?(_identifier), do: false

  defp calendar_event_identifier(meeting) do
    if present_identifier?(meeting.provider_event_id) do
      meeting.provider_event_id
    else
      meeting.uid
    end
  end

  defp update_or_create_calendar_event(meeting, event_data) do
    case update_existing_event(meeting, event_data) do
      {:error, :not_found} -> handle_missing_event(meeting.id, event_data, meeting)
      result -> result
    end
  end

  defp update_existing_event(meeting, event_data) do
    case calendar_module().update_event(calendar_event_identifier(meeting), event_data, meeting) do
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

  defp handle_missing_event(meeting_id, event_data, meeting) do
    Logger.info("Calendar event not found, creating new one", meeting_id: meeting_id)

    # Use the organizer_user_id to create in the correct calendar
    case calendar_module().create_event(event_data, meeting.organizer_user_id) do
      {:ok, created} ->
        persist_or_compensate(meeting, created)

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

        update_existing_event(meeting, event_data)

      error ->
        error
    end
  end

  defp delete_event_for_meeting(meeting, meeting_id) do
    case calendar_module().delete_event(calendar_event_identifier(meeting), meeting) do
      :ok ->
        Logger.info("Calendar event deleted successfully", meeting_id: meeting_id)
        :ok

      {:ok, :deleted} ->
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
    Logger.info("Creating calendar event", meeting_id: meeting_id, uid: meeting.uid)

    event_data = CalendarEventBuilder.build_event_data(meeting)

    # Use the meeting context to create in the correct calendar
    case calendar_module().create_event(event_data, meeting) do
      {:ok, created} ->
        Logger.info("Calendar event created successfully", meeting_id: meeting_id)

        persist_or_compensate(meeting, created)

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

  # Persist the provider mapping after a successful create. If persistence
  # fails, the provider event already exists but the meeting doesn't carry its
  # UID/provider_event_id — so a worker retry of `create` would create a
  # DUPLICATE (server-assigned-ID providers like Google/Outlook can't detect
  # the orphan). To keep the operation idempotent we compensate by deleting the
  # just-created event before surfacing the error, leaving the retry a clean
  # slate. CalDAV PUTs are idempotent on the caller-supplied UID, so a failed
  # delete there is harmless; the compensation primarily guards Google/Outlook.
  #
  # `base_attrs` go into the same write as the mapping.
  defp persist_or_compensate(meeting, %CreatedEvent{} = created, base_attrs \\ %{}) do
    case persist_calendar_mapping(meeting, created, base_attrs) do
      :ok ->
        :ok

      {:error, reason} ->
        compensate_orphaned_event(meeting, created)
        {:error, reason}
    end
  end

  # Best-effort deletion of an event that was created on the provider but whose
  # mapping could not be persisted. Uses the provider identifier returned by the
  # create call so the delete targets the exact orphan, independent of whatever
  # (stale, unpersisted) UID the meeting still carries.
  defp compensate_orphaned_event(meeting, %CreatedEvent{} = created) do
    Logger.warning(
      "Calendar mapping persistence failed after create; deleting orphaned event to keep retry idempotent",
      meeting_id: meeting.id
    )

    discard_created_event(meeting, created)
  end

  defp discard_created_event(meeting, %CreatedEvent{} = created) do
    case CreatedEvent.local_uid(created) do
      nil -> :ok
      identifier -> delete_orphan(meeting, identifier)
    end
  end

  defp delete_orphan(meeting, identifier) do
    case calendar_module().delete_event(identifier, meeting) do
      :ok ->
        :ok

      {:ok, :deleted} ->
        :ok

      {:error, :not_found} ->
        :ok

      other ->
        Logger.error("Failed to delete orphaned calendar event after persistence failure",
          meeting_id: meeting.id,
          result: inspect(other)
        )

        :ok
    end
  end

  defp handle_create_event_error(error_type, meeting, meeting_id, attempt) do
    case error_type do
      :rate_limited ->
        {:error, :rate_limited}

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
          error: inspect(reason)
        )
    end
  end

  # Persist which integration and calendar path were used for creation. With
  # no integration to name, a plain create records nothing, as it always has;
  # a write that carries `base_attrs` still records the new event, since a
  # replacement must never leave the meeting on the event it is about to
  # delete.
  defp persist_calendar_mapping(meeting, created, base_attrs) do
    case calendar_module().get_booking_integration_info(meeting) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        attrs =
          Map.merge(base_attrs, %{
            calendar_integration_id: integration_id,
            calendar_path: calendar_path
          })

        write_calendar_mapping(meeting, put_provider_mapping(attrs, created))

      _no_integration_info when map_size(base_attrs) == 0 ->
        :ok

      _no_integration_info ->
        write_calendar_mapping(meeting, put_provider_mapping(base_attrs, created))
    end
  end

  defp write_calendar_mapping(meeting, attrs) do
    case MeetingQueries.update_meeting(meeting, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to persist calendar mapping",
          meeting_id: meeting.id,
          error: inspect(changeset.errors)
        )

        {:error, :calendar_mapping_persistence_failed}
    end
  end

  # A provider that reported an iCalendar UID (the CalDAV family) has confirmed
  # the value the meeting is keyed by. Every other provider answers with an
  # identifier it minted, which belongs in `provider_event_id`: writing it to
  # `uid` would key the meeting by a value no sync ever produces.
  #
  # A CalDAV create now also reports the resource's href, and that is
  # deliberately not persisted here. `calendar_event_identifier/1` hands
  # `provider_event_id` back as the uid of the next write, and an href is not
  # one. It belongs on the cached grid row, which addresses events by URL.
  defp put_provider_mapping(attrs, %CreatedEvent{uid: uid}) when is_binary(uid),
    do: Map.put(attrs, :uid, uid)

  defp put_provider_mapping(attrs, %CreatedEvent{provider_event_id: id}) when is_binary(id),
    do: Map.put(attrs, :provider_event_id, id)

  defp put_provider_mapping(attrs, %CreatedEvent{}), do: attrs

  defp calendar_module do
    Application.get_env(:tymeslot, :calendar_module) ||
      Tymeslot.Integrations.Calendar.Events
  end
end
