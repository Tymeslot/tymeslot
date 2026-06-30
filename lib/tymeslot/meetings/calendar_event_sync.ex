defmodule Tymeslot.Meetings.CalendarEventSync do
  @moduledoc """
  Domain orchestration for synchronising meeting calendar events with the
  configured calendar provider (CalDAV, Google, Outlook).

  This module owns the *what* of calendar synchronisation — the create, update
  and delete flows, including:

  - the create→update fallback when a meeting already carries an external UID,
  - the update→create-on-404 recovery,
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
  alias Tymeslot.Meetings.MeetingQueries
  require Logger

  @doc """
  Creates a calendar event for the given meeting.

  If the meeting already carries an external UID (i.e. another worker, such as
  the video-room worker, already created the event), this switches to an update
  so all fields stay in sync.

  The `attempt` count is used only to decide whether a persistent failure should
  trigger an owner notification.
  """
  @spec create(term(), pos_integer()) :: :ok | {:error, term()} | {:discard, term()}
  def create(meeting_id, attempt) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        Logger.metadata(user_id: meeting.organizer_user_id)

        # If the meeting already has an external UID (not a UUID), it means
        # another worker (like VideoRoomWorker for Teams) already created the event.
        # In this case, we switch to an update operation to ensure all fields are synced.
        if external_id?(meeting.uid) do
          Logger.info("Meeting already has external UID, switching to update",
            meeting_id: meeting_id,
            uid: meeting.uid
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
        Logger.info("Updating calendar event", meeting_id: meeting_id, uid: meeting.uid)
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
        Logger.info("Deleting calendar event", meeting_id: meeting_id, uid: meeting.uid)

        delete_event_for_meeting(meeting, meeting_id)

      {:error, :not_found} ->
        # Meeting doesn't exist, but deletion can still succeed
        Logger.info("Meeting not found but proceeding with calendar deletion",
          meeting_id: meeting_id
        )

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Internal orchestration
  # ---------------------------------------------------------------------------

  defp external_id?(nil), do: false

  defp external_id?(uid) do
    case UUID.cast(uid) do
      {:ok, _uuid} -> false
      :error -> true
    end
  end

  defp update_or_create_calendar_event(meeting, event_data) do
    case calendar_module().update_event(meeting.uid, event_data, meeting) do
      :ok ->
        Logger.info("Calendar event updated successfully", meeting_id: meeting.id)
        :ok

      {:ok, _result} ->
        # Backward/forward compatibility if update returns tagged tuple
        Logger.info("Calendar event updated successfully", meeting_id: meeting.id)
        :ok

      {:error, :not_found} ->
        handle_missing_event(meeting.id, event_data, meeting)

      error ->
        error
    end
  end

  defp handle_missing_event(meeting_id, event_data, meeting) do
    Logger.info("Calendar event not found, creating new one", meeting_id: meeting_id)

    # Use the organizer_user_id to create in the correct calendar
    case calendar_module().create_event(event_data, meeting.organizer_user_id) do
      {:ok, result} ->
        # Persist the new UID so future updates target the correct event
        returned_uid = if is_map(result), do: Map.get(result, :uid), else: nil

        persist_or_compensate(meeting, returned_uid, result)

      error ->
        error
    end
  end

  defp delete_event_for_meeting(meeting, meeting_id) do
    case calendar_module().delete_event(meeting.uid, meeting) do
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
      {:ok, returned_uid} ->
        Logger.info("Calendar event created successfully", meeting_id: meeting_id)

        persist_or_compensate(meeting, returned_uid, returned_uid)

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
  defp persist_or_compensate(meeting, returned_uid, created_event) do
    case persist_calendar_mapping(meeting, returned_uid) do
      :ok ->
        :ok

      {:error, reason} ->
        compensate_orphaned_event(meeting, created_event)
        {:error, reason}
    end
  end

  # Best-effort deletion of an event that was created on the provider but whose
  # mapping could not be persisted. Uses the provider identifier returned by the
  # create call so the delete targets the exact orphan, independent of whatever
  # (stale, unpersisted) UID the meeting still carries.
  defp compensate_orphaned_event(meeting, created_event) do
    case orphan_identifier(created_event) do
      nil ->
        :ok

      identifier ->
        Logger.warning(
          "Calendar mapping persistence failed after create; deleting orphaned event to keep retry idempotent",
          meeting_id: meeting.id
        )

        delete_orphan(meeting, identifier)
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

  defp orphan_identifier(uid) when is_binary(uid), do: uid
  defp orphan_identifier(%{"id" => id}) when is_binary(id), do: id
  defp orphan_identifier(%{id: id}) when is_binary(id), do: id
  defp orphan_identifier(%{"uid" => uid}) when is_binary(uid), do: uid
  defp orphan_identifier(%{uid: uid}) when is_binary(uid), do: uid
  defp orphan_identifier(_other), do: nil

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

  defp persist_calendar_mapping(meeting, returned_value) do
    # Persist which integration and calendar path were used for creation
    case calendar_module().get_booking_integration_info(meeting) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        attrs = %{
          calendar_integration_id: integration_id,
          calendar_path: calendar_path
        }

        # If the provider returned a specific UID (string), save it to the meeting
        # so subsequent updates can use it.
        attrs = put_provider_mapping(attrs, returned_value)

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

      _no_integration_info ->
        :ok
    end
  end

  # If the provider returned a specific UID (string), save it to the meeting so
  # subsequent updates can use it. Google returns the raw JSON-decoded map with
  # string keys; Outlook returns the common-format map with atom keys.
  defp put_provider_mapping(attrs, uid) when is_binary(uid),
    do: Map.put(attrs, :uid, uid)

  defp put_provider_mapping(attrs, %{"id" => provider_id}) when is_binary(provider_id),
    do: Map.put(attrs, :provider_event_id, provider_id)

  defp put_provider_mapping(attrs, %{id: provider_id}) when is_binary(provider_id),
    do: Map.put(attrs, :provider_event_id, provider_id)

  defp put_provider_mapping(attrs, _other), do: attrs

  defp calendar_module do
    Application.get_env(:tymeslot, :calendar_module) ||
      Tymeslot.Integrations.Calendar.Events
  end
end
