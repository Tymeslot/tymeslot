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

  alias Tymeslot.Integrations.Calendar.CalDAV.QueueWiring
  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.RetryHelpers
  require Logger

  # Configuration
  # 90 seconds for CalDAV operations (increased for background retries).
  #
  # Read at runtime rather than through `Application.compile_env/3`, which is
  # this project's default: a compiled-in constant cannot be lowered by the test
  # that exercises the timeout branch, so that test sat waiting out the full 90
  # seconds and was half the Core suite's wall clock on its own. One
  # `Application.get_env/3` per job is not a hot path.
  @default_calendar_timeout_ms 90_000

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
        Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
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
      "create" -> CalendarEventSync.create(meeting_id, attempt)
      "update" -> CalendarEventSync.update(meeting_id, attempt)
      "delete" -> CalendarEventSync.delete(meeting_id, attempt)
      _unknown -> {:discard, "Unknown action: #{action}"}
    end
  end

  defp calendar_timeout_ms do
    Application.get_env(:tymeslot, :calendar_timeout_ms, @default_calendar_timeout_ms)
  end

  defp handle_task_result(task, action, meeting_id, job) do
    timeout_ms = calendar_timeout_ms()

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        handle_result(result, job)

      {:exit, reason} ->
        Logger.error("Calendar operation crashed",
          action: action,
          meeting_id: meeting_id,
          reason: inspect(reason)
        )

        {:error, "Calendar operation crashed: #{inspect(reason)}"}

      nil ->
        Logger.error("Calendar operation timed out",
          action: action,
          meeting_id: meeting_id,
          timeout_ms: timeout_ms
        )

        # Snooze instead of error to give the server recovery time before
        # the next attempt, especially important before the final attempt.
        {:snooze, 300}
    end
  end

  # Private functions

  defp handle_result(result, job) do
    case result do
      :ok ->
        clear_offline_queue_tag(job)
        :ok

      {:error, error_type} ->
        tag_for_offline_queue(job, error_type)
        handle_error_result(error_type, job)

      {:error, error_type, message} when is_binary(message) ->
        tag_for_offline_queue(job, error_type)
        handle_error_result(error_type, job, message)

      {:discard, reason} ->
        {:discard, reason}

      _unexpected ->
        handle_unexpected_result(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Offline queue integration (CalDAV only)
  # ---------------------------------------------------------------------------

  # Errors that cannot be recovered by a later retry — tagging them would
  # only keep a dead row in the queue forever.
  @non_queueable_errors [:unauthorized, :not_found, :meeting_not_found, :rate_limited]

  defp tag_for_offline_queue(_job, error_type) when error_type in @non_queueable_errors, do: :ok

  defp tag_for_offline_queue(%Oban.Job{args: args}, _error_type) do
    action = args["action"]
    meeting_id = args["meeting_id"]

    with {:ok, meeting} <- MeetingQueries.get_meeting(meeting_id),
         action_atom when action_atom in [:create, :update, :delete] <- action_to_atom(action) do
      event_data = CalendarEventBuilder.build_event_data(meeting)
      QueueWiring.tag(meeting, action_atom, event_data)
    else
      _other -> :ok
    end
  end

  defp clear_offline_queue_tag(%Oban.Job{args: args}) do
    case MeetingQueries.get_meeting(args["meeting_id"]) do
      {:ok, meeting} -> QueueWiring.clear(meeting, nil)
      {:error, _reason} -> :ok
    end
  end

  defp action_to_atom("create"), do: :create
  defp action_to_atom("update"), do: :update
  defp action_to_atom("delete"), do: :delete
  defp action_to_atom(_other), do: nil

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

  defp handle_error_result(:precondition_failed, %Oban.Job{args: %{"action" => "update"}}) do
    # A 412 means the server's ETag no longer matches the one we sent: someone
    # else changed the event. Replaying the identical conditional PUT cannot
    # resolve that — it fails the same way on every attempt, and spends the
    # job's remaining attempts to arrive at a permanent-failure alert.
    #
    # The write is not lost. `tag_for_offline_queue/2` has already marked the
    # cache row `locally_modified`, and `CalDAV.OfflineQueue` replays it on the
    # next sync cycle under the row's conflict policy — `:keep_local` for events
    # Tymeslot owns, which force-writes and actually settles the conflict.
    Logger.info("Calendar event changed on the server, handing the write to the offline queue")

    {:discard, "Conflicting server-side change; queued for offline replay"}
  end

  defp handle_error_result(:precondition_failed, _job) do
    # Only an update may hand a 412 to the offline queue. On a create the 412
    # comes from `If-None-Match: *` finding an event already at the UID, and the
    # queue replays creates without a conflict policy, so it would 412 again on
    # every sync cycle without ever alerting anyone. Keep the ordinary retry
    # path, whose exhaustion still surfaces the problem.
    {:error, :precondition_failed}
  end

  defp handle_error_result(:circuit_open, _job) do
    # The host circuit breaker is open — the CalDAV server is unreachable right now.
    # Snooze for the circuit recovery timeout (2 min for caldav/zimbra) so the breaker
    # has time to transition to half-open before the next attempt, rather than burning
    # retry slots against a still-open circuit.
    {:snooze, 120}
  end

  defp handle_error_result(:server_unresponsive, _job) do
    # The CalDAV server accepted the TCP connection but did not respond
    # within the write deadline. Retrying immediately is actively harmful:
    # each mid-flight interruption can leave the server holding a stale
    # file lock, worsening the condition that's slowing it down in the
    # first place. Back off for 10 minutes so the server has a real chance
    # to recover (whatever was slowing it — backup, GC pause, lock
    # contention from another client) before we touch it again. Oban's
    # default max_attempts: 5 combined with this snooze gives ~50 minutes
    # of graceful retry before the job is considered genuinely stuck.
    Logger.warning(
      "CalDAV server unresponsive on write, snoozing 10 minutes to avoid worsening wedge"
    )

    {:snooze, 600}
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
    retry_after = RetryHelpers.parse_retry_after_from_message(message) || parse_retry_after(job)

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
        RetryHelpers.parse_retry_after_from_message(msg)

      _no_error ->
        nil
    end
  end

  defp handle_unexpected_result(result) do
    Logger.error("Unexpected result from calendar job", result: result)
    {:error, "Unexpected result"}
  end
end
