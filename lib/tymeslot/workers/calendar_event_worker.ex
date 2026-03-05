defmodule Tymeslot.Workers.CalendarEventWorker do
  @moduledoc """
  Oban worker for handling calendar event creation and updates with intelligent retry logic.

  This worker handles:
  - Async creation of calendar events in CalDAV servers
  - Smart retry logic with progressive backoff
  - Error categorization for appropriate handling
  - Timeouts for CalDAV operations
  - Error notifications to calendar owner on persistent failures

  Total retry duration: ~18 minutes
  - 5 attempts with 90s timeout each = 450s
  - Backoff delays: 30s + 60s + 120s + 180s = 390s
  - Total: 840s ≈ 14 minutes (plus processing time ≈ 18 minutes)
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    # High priority for calendar sync
    priority: 1

  alias Ecto.{Changeset, UUID}
  alias Tymeslot.DatabaseQueries.MeetingQueries
  require Logger

  # Configuration
  # 90 seconds for CalDAV operations (increased for background retries)
  @calendar_timeout_ms 90_000

  @doc """
  Performs the calendar event operation based on the action specified.
  """
  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"action" => action, "meeting_id" => meeting_id}, attempt: attempt} = job
      ) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    if Application.get_env(:tymeslot, :test_mode, false) do
      # In test mode, run synchronously to avoid SQL sandbox and Mox allowance issues
      # with child processes created by Task.async
      result = dispatch_action(action, meeting_id, attempt)
      handle_result(result, job)
    else
      task =
        Task.async(fn ->
          dispatch_action(action, meeting_id, attempt)
        end)

      handle_task_result(task, action, meeting_id, job)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Progressive backoff: 30s, 60s, 120s, 180s
    case attempt do
      1 -> 30
      2 -> 60
      3 -> 120
      4 -> 180
      _other_attempt -> 30
    end
  end

  defp dispatch_action(action, meeting_id, attempt) do
    case action do
      "create" -> handle_calendar_creation(meeting_id, attempt)
      "update" -> handle_calendar_update(meeting_id, attempt)
      "delete" -> handle_calendar_deletion(meeting_id, attempt)
      _unknown -> {:discard, "Unknown action: #{action}"}
    end
  end

  defp handle_task_result(task, action, meeting_id, job) do
    case Task.yield(task, @calendar_timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        handle_result(result, job)

      nil ->
        Logger.error("Calendar operation timed out",
          action: action,
          meeting_id: meeting_id,
          timeout_ms: @calendar_timeout_ms
        )

        {:error, "Calendar operation timed out"}
    end
  end

  @doc """
  Schedules calendar event creation to happen asynchronously with high priority.
  """
  @spec schedule_calendar_creation(integer()) :: :ok | {:error, String.t()}
  def schedule_calendar_creation(meeting_id) do
    result =
      %{"action" => "create", "meeting_id" => meeting_id}
      |> new(
        queue: :calendar_events,
        # Highest priority for calendar sync
        priority: 0,
        unique: [
          # 5 minutes uniqueness window
          period: 300,
          fields: [:args, :queue],
          keys: [:action, :meeting_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Calendar event creation job scheduled", meeting_id: meeting_id)
        :ok

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.info("Calendar event creation job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar event creation",
          meeting_id: meeting_id,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules calendar event update with medium priority.
  """
  @spec schedule_calendar_update(String.t() | integer()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def schedule_calendar_update(meeting_id) do
    %{"action" => "update", "meeting_id" => meeting_id}
    |> new(
      queue: :calendar_events,
      # Medium priority for updates
      priority: 2,
      unique: [
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id]
      ]
    )
    |> Oban.insert()
  end

  @doc """
  Schedules calendar event deletion with high priority.
  """
  @spec schedule_calendar_deletion(String.t() | integer()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def schedule_calendar_deletion(meeting_id) do
    %{"action" => "delete", "meeting_id" => meeting_id}
    |> new(
      queue: :calendar_events,
      # High priority for deletions
      priority: 1,
      unique: [
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id]
      ]
    )
    |> Oban.insert()
  end

  # Private functions

  defp format_insert_error(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  defp format_insert_error(other), do: inspect(other)

  defp handle_result(result, job) do
    case result do
      :ok ->
        :ok

      {:error, error_type} ->
        handle_error_result(error_type, job)

      {:error, error_type, message} when is_binary(message) ->
        handle_error_result(error_type, job, message)

      {:discard, reason} ->
        {:discard, reason}

      _unexpected ->
        handle_unexpected_result(result)
    end
  end

  # Group all handle_error_result/2 clauses together
  defp handle_error_result(:rate_limited, job) do
    # If provider supplied Retry-After in error message, honor it
    retry_after = parse_retry_after(job)

    snooze_seconds =
      if is_integer(retry_after) do
        min(600, max(10, retry_after))
      else
        # fallback heuristic
        min(300, 60 * job.attempt)
      end

    Logger.warning("Calendar service rate limited, snoozing",
      snooze_seconds: snooze_seconds
    )

    {:snooze, snooze_seconds}
  end

  defp handle_error_result(:unauthorized, _job) do
    Logger.error("Calendar authentication failed, discarding job")
    {:discard, "Authentication failed"}
  end

  defp handle_error_result(:not_found, job) do
    # Event doesn't exist, check if it's OK based on action
    action = job.args["action"]

    if action in ["update", "delete"] do
      Logger.info("Calendar event not found, considering success", action: action)
      :ok
    else
      {:error, :not_found}
    end
  end

  defp handle_error_result(:meeting_not_found, _job) do
    Logger.error("Meeting not found, discarding job")
    {:discard, "Meeting not found"}
  end

  defp handle_error_result(:circuit_open, _job) do
    # The host circuit breaker is open — the CalDAV server is unreachable right now.
    # Snooze for the circuit recovery timeout (2 min for caldav/zimbra) so the breaker
    # has time to transition to half-open before the next attempt, rather than burning
    # retry slots against a still-open circuit.
    {:snooze, 120}
  end

  defp handle_error_result(:connection_failed, _job) do
    # Network issues - use longer backoff
    # Retry in 1 minute
    {:snooze, 60}
  end

  defp handle_error_result(reason, _job) when is_binary(reason) do
    # Generic error - retry with backoff
    {:error, reason}
  end

  defp handle_error_result(reason, _job) do
    # Unknown error format - return as-is for retry
    {:error, reason}
  end

  # Group all handle_error_result/3 clauses together, after the /2 clauses
  defp handle_error_result(:rate_limited, job, message) do
    retry_after = parse_retry_after_message(message) || parse_retry_after(job)

    snooze_seconds =
      if is_integer(retry_after),
        do: min(600, max(10, retry_after)),
        else: min(300, 60 * job.attempt)

    Logger.warning("Calendar service rate limited, snoozing", snooze_seconds: snooze_seconds)
    {:snooze, snooze_seconds}
  end

  # Helpers
  defp parse_retry_after(%Oban.Job{errors: errors}) do
    # Try to extract retry_after:N from last error message (if present)
    case List.last(errors) do
      %{"attempt" => _attempt_number, "error" => msg} when is_binary(msg) ->
        parse_retry_after_message(msg)

      _no_error ->
        nil
    end
  end

  defp parse_retry_after_message(msg) when is_binary(msg) do
    case Regex.run(~r/retry_after:(\d+)/i, msg) do
      [_match, n] -> String.to_integer(n)
      _nomatch -> nil
    end
  end

  defp handle_unexpected_result(result) do
    Logger.error("Unexpected result from calendar job", result: result)
    {:error, "Unexpected result"}
  end

  defp handle_calendar_creation(meeting_id, attempt) do
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

          handle_calendar_update(meeting_id, attempt)
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

  defp external_id?(nil), do: false

  defp external_id?(uid) do
    case UUID.cast(uid) do
      {:ok, _uuid} -> false
      :error -> true
    end
  end

  defp handle_calendar_update(meeting_id, _attempt) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        Logger.metadata(user_id: meeting.organizer_user_id)
        Logger.info("Updating calendar event", meeting_id: meeting_id, uid: meeting.uid)
        event_data = build_event_data(meeting)
        update_or_create_calendar_event(meeting_id, meeting.uid, event_data)

      {:error, :not_found} ->
        {:error, :meeting_not_found}
    end
  end

  defp build_event_data(meeting) do
    %{
      uid: meeting.uid,
      summary: meeting.title,
      description: build_event_description(meeting),
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      timezone: meeting.attendee_timezone,
      location: meeting.meeting_url || meeting.location || "To be determined",
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email
    }
  end

  defp update_or_create_calendar_event(meeting_id, uid, event_data) do
    # Get the calendar integration ID from the meeting
    {:ok, meeting} = MeetingQueries.get_meeting(meeting_id)

    case calendar_module().update_event(uid, event_data, meeting) do
      :ok ->
        Logger.info("Calendar event updated successfully", meeting_id: meeting_id)
        :ok

      {:ok, _result} ->
        # Backward/forward compatibility if update returns tagged tuple
        Logger.info("Calendar event updated successfully", meeting_id: meeting_id)
        :ok

      {:error, :not_found} ->
        handle_missing_event(meeting_id, event_data, meeting)

      error ->
        error
    end
  end

  defp handle_missing_event(meeting_id, event_data, meeting) do
    Logger.info("Calendar event not found, creating new one", meeting_id: meeting_id)

    # Use the organizer_user_id to create in the correct calendar
    case calendar_module().create_event(event_data, meeting.organizer_user_id) do
      {:ok, _result} -> :ok
      error -> error
    end
  end

  defp handle_calendar_deletion(meeting_id, _attempt) do
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

      {:error, :not_found} ->
        # Meeting doesn't exist, but deletion can still succeed
        Logger.info("Meeting not found but proceeding with calendar deletion",
          meeting_id: meeting_id
        )

        :ok
    end
  end

  defp build_event_description(meeting) do
    parts = [
      meeting.description,
      if(meeting.attendee_message, do: "\n\nMessage from attendee:\n#{meeting.attendee_message}"),
      if(meeting.meeting_url, do: "\n\nVideo meeting: #{meeting.meeting_url}")
    ]

    parts
    |> Enum.filter(& &1)
    |> Enum.join()
  end

  defp create_event_for_meeting(meeting, meeting_id, attempt) do
    Logger.info("Creating calendar event", meeting_id: meeting_id, uid: meeting.uid)

    event_data = build_event_data(meeting)

    # Use the meeting context to create in the correct calendar
    case calendar_module().create_event(event_data, meeting) do
      {:ok, returned_uid} ->
        Logger.info("Calendar event created successfully", meeting_id: meeting_id)
        # Pass the returned UID to persist it
        persist_calendar_mapping(meeting, returned_uid)
        :ok

      {:error, error_type} ->
        handle_create_event_error(error_type, meeting, meeting_id, attempt)
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
    email_service_module().send_calendar_sync_error(meeting, error_reason)
  end

  defp email_service_module do
    Application.get_env(:tymeslot, :email_service_module) ||
      Tymeslot.Emails.EmailService
  end

  defp persist_calendar_mapping(meeting, returned_uid) do
    # Persist which integration and calendar path were used for creation
    case calendar_module().get_booking_integration_info(meeting) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        attrs = %{
          calendar_integration_id: integration_id,
          calendar_path: calendar_path
        }

        # If the provider returned a specific UID, save it to the meeting
        # so subsequent updates can use it.
        attrs = if returned_uid, do: Map.put(attrs, :uid, returned_uid), else: attrs

        _update_result = MeetingQueries.update_meeting(meeting, attrs)

      _no_integration_info ->
        :ok
    end
  end

  defp calendar_module do
    Application.get_env(:tymeslot, :calendar_module) ||
      Tymeslot.Integrations.Calendar
  end
end
