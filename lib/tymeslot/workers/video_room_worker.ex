defmodule Tymeslot.Workers.VideoRoomWorker do
  @moduledoc """
  Oban worker for handling video room creation jobs with intelligent retry logic.

  This worker handles:
  - Async creation of MiroTalk video rooms after meeting is confirmed
  - Smart retry logic with exponential backoff
  - Error categorization for appropriate handling
  - Timeouts for API operations
  - Updates meeting record with video room details when successful
  - Graceful degradation when video creation fails
  """

  use Oban.Worker,
    queue: :video_rooms,
    max_attempts: 5,
    # Highest priority for video room creation
    priority: 0

  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Meetings
  require Logger

  # Configuration
  # 20 seconds for video API calls
  @video_api_timeout_ms 20_000
  # 1 second base for exponential backoff
  @backoff_base_ms 1_000

  @doc """
  Performs the video room creation job with exponential backoff for retries.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id} = args, attempt: attempt} = job) do
    send_emails = Map.get(args, "send_emails", false)
    # Ensure meeting_id is a string to satisfy downstream specs
    meeting_id = to_string(meeting_id)

    # Apply exponential backoff for retries (but not on first attempt)
    if attempt > 1 and not Application.get_env(:tymeslot, :test_mode, false) do
      backoff_ms = calculate_backoff(attempt)

      Logger.info("Retrying video room creation after backoff",
        meeting_id: meeting_id,
        attempt: attempt,
        backoff_ms: backoff_ms
      )

      Process.sleep(backoff_ms)
    end

    Logger.info("Starting video room creation",
      meeting_id: meeting_id,
      send_emails: send_emails,
      attempt: attempt
    )

    # Execute with timeout
    task =
      Task.async(fn ->
        Meetings.add_video_room_to_meeting(meeting_id)
      end)

    case Task.yield(task, @video_api_timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, meeting}} ->
        :ok = handle_success(meeting, send_emails)
        :ok

      {:ok, {:error, reason}} ->
        result_after_error = handle_error(reason, meeting_id, send_emails, attempt)
        handle_result(result_after_error, job)

      {:ok, result} ->
        handle_result(result, job)

      nil ->
        Logger.error("Video room creation timed out",
          meeting_id: meeting_id,
          timeout_ms: @video_api_timeout_ms
        )

        handle_timeout_with_fallback(meeting_id, send_emails, attempt)
    end
  end

  @doc """
  Schedules video room creation to happen asynchronously with highest priority.
  """
  @spec schedule_video_room_creation(String.t()) :: :ok | {:error, String.t()}
  def schedule_video_room_creation(meeting_id) do
    result =
      %{"meeting_id" => meeting_id, "send_emails" => false}
      |> new(
        queue: :video_rooms,
        # Highest priority
        priority: 0,
        unique: [
          # 5 minutes uniqueness window
          period: 300,
          fields: [:args, :queue],
          keys: [:meeting_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Video room creation job scheduled", meeting_id: meeting_id)
        :ok

      {:error, %Ecto.Changeset{errors: [unique: _]}} ->
        Logger.info("Video room creation job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        # Return success since job already exists
        :ok

      {:error, changeset} ->
        Logger.error("Failed to schedule video room creation",
          meeting_id: meeting_id,
          error: inspect(changeset)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules video room creation and emails after completion with highest priority.
  Emails will be sent after video room creation completes (success or final failure).
  """
  @spec schedule_video_room_creation_with_emails(String.t()) :: :ok | {:error, String.t()}
  def schedule_video_room_creation_with_emails(meeting_id) do
    result =
      %{"meeting_id" => meeting_id, "send_emails" => true}
      |> new(
        queue: :video_rooms,
        # Highest priority for user-facing features
        priority: 0,
        unique: [
          # 5 minutes uniqueness window
          period: 300,
          fields: [:args, :queue],
          keys: [:meeting_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Video room creation with emails job scheduled",
          meeting_id: meeting_id
        )

        :ok

      {:error, %Ecto.Changeset{errors: [unique: _]}} ->
        Logger.info("Video room creation job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        # Return success since job already exists
        :ok

      {:error, changeset} ->
        Logger.error("Failed to schedule video room creation with emails",
          meeting_id: meeting_id,
          error: inspect(changeset)
        )

        {:error, "Failed to schedule job"}
    end
  end

  # Private functions

  defp handle_result(result, job) do
    case result do
      :ok ->
        :ok

      {:error, error_type} ->
        handle_video_error(error_type, job)

      {:discard, reason} ->
        {:discard, reason}

      _ ->
        handle_unexpected_video_result(result)
    end
  end

  defp handle_video_error(:rate_limited, job) do
    # MiroTalk API rate limited us
    # Max 5 minutes
    snooze_seconds = min(300, 60 * job.attempt)

    Logger.warning("Video API rate limited, snoozing",
      snooze_seconds: snooze_seconds
    )

    {:snooze, snooze_seconds}
  end

  defp handle_video_error(:unauthorized, _job) do
    Logger.error("Video API authentication failed, discarding job")
    {:discard, "Authentication failed"}
  end

  defp handle_video_error(:meeting_not_found, _job) do
    Logger.error("Meeting not found, discarding job")
    {:discard, "Meeting not found"}
  end

  defp handle_video_error(:invalid_configuration, _job) do
    Logger.error("Invalid video service configuration, discarding job")
    {:discard, "Invalid configuration"}
  end

  defp handle_video_error(:service_unavailable, _job) do
    # Service is down - use longer backoff
    # Retry in 2 minutes
    {:snooze, 120}
  end

  defp handle_video_error(reason, _job) when is_binary(reason) do
    # Generic error - retry with backoff
    {:error, reason}
  end

  defp handle_video_error(reason, _job) do
    # Unknown error format - return as-is for retry
    {:error, reason}
  end

  defp handle_unexpected_video_result(result) do
    Logger.error("Unexpected result from video room job", result: inspect(result))
    {:error, "Unexpected result"}
  end

  defp calculate_backoff(attempt) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s
    round(min(@backoff_base_ms * :math.pow(2, attempt - 1), 16_000))
  end

  defp handle_success(meeting_with_video, send_emails) do
    # Be tolerant of different shapes; extract id/room_id if present
    meeting_id = Map.get(meeting_with_video, :id)
    room_id = Map.get(meeting_with_video, :video_room_id)

    Logger.info("Video room created successfully",
      meeting_id: meeting_id,
      room_id: room_id
    )

    if send_emails and meeting_id do
      Logger.info("Scheduling emails with video room info", meeting_id: meeting_id)
      Meetings.schedule_email_notifications(meeting_with_video)
    end

    :ok
  end

  defp handle_error(reason, meeting_id, send_emails, attempt) do
    Logger.error("Failed to create video room",
      meeting_id: meeting_id,
      reason: inspect(reason),
      attempt: attempt
    )

    # Categorize the error
    categorized_error = categorize_error(reason)

    # If this is the final attempt and emails should be sent, send them without video
    if send_emails and attempt >= 5 do
      send_fallback_emails(meeting_id)
    end

    categorized_error
  end

  defp handle_timeout_with_fallback(meeting_id, send_emails, attempt) do
    # If this is the final attempt and emails should be sent, send them without video
    if send_emails and attempt >= 5 do
      send_fallback_emails(meeting_id)
    end

    {:error, "Video room creation timed out"}
  end

  defp send_fallback_emails(meeting_id) do
    Logger.info("Sending emails without video room due to creation failure",
      meeting_id: meeting_id
    )

    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        Meetings.schedule_email_notifications(meeting)

      {:error, _} ->
        Logger.error("Could not fetch meeting for fallback email scheduling",
          meeting_id: meeting_id
        )
    end
  end

  @spec categorize_error(term()) :: {:error, atom() | term()}
  defp categorize_error({:unauthorized, _}), do: {:error, :unauthorized}
  defp categorize_error(:unauthorized), do: {:error, :unauthorized}

  defp categorize_error({:configuration_error, _}), do: {:error, :invalid_configuration}
  defp categorize_error(:configuration_error), do: {:error, :invalid_configuration}

  defp categorize_error({:http_error, status}) when is_integer(status) and status in 500..599,
    do: {:error, :service_unavailable}

  defp categorize_error(:rate_limited), do: {:error, :rate_limited}
  defp categorize_error(:not_found), do: {:error, :meeting_not_found}
  defp categorize_error(other), do: {:error, other}
end
