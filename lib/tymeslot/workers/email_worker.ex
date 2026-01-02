defmodule Tymeslot.Workers.EmailWorker do
  @moduledoc """
  Oban worker for handling email sending jobs with intelligent retry and error handling.

  This worker handles:
  - Sending confirmation emails after meeting creation
  - Sending reminder emails before meetings
  - Smart retry logic with exponential backoff
  - Error categorization for appropriate handling
  - Timeouts for external service calls
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    # Higher priority (0-3, lower number = higher priority)
    priority: 1

  alias Ecto.Changeset
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Workers.EmailWorkerHandlers
  require Logger

  # Configuration
  # 30 seconds
  @email_timeout_ms 30_000
  # 1 second base for exponential backoff
  @backoff_base_ms 1_000

  @doc """
  Performs the email job based on the action specified in the args.
  Implements exponential backoff for retries.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => action} = args, attempt: _attempt} = job) do
    execute_email_job_with_timeout(action, args, job)
  end

  def perform(%Oban.Job{args: args} = job) do
    Logger.error("EmailWorker job missing action parameter",
      args: inspect(args),
      job_id: job.id,
      attempt: job.attempt
    )

    {:discard, "Missing action parameter"}
  end

  @doc """
  Schedules confirmation emails to be sent immediately with high priority.
  """
  @spec schedule_confirmation_emails(term()) :: :ok | {:error, String.t()}
  def schedule_confirmation_emails(meeting_id) do
    result =
      %{"action" => "send_confirmation_emails", "meeting_id" => meeting_id}
      |> new(
        queue: :emails,
        # Highest priority for confirmations
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
        Logger.info("Confirmation email job scheduled", meeting_id: meeting_id)
        :ok

      {:error, %Ecto.Changeset{errors: [unique: _]}} ->
        Logger.info("Confirmation email job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        # Return success since job already exists
        :ok

      {:error, changeset} ->
        Logger.error("Failed to schedule confirmation emails",
          meeting_id: meeting_id,
          error: inspect(changeset)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules user email verification immediately with high priority.
  """
  @spec schedule_email_verification(term(), String.t()) :: :ok | {:error, String.t()}
  def schedule_email_verification(user_id, verification_url) do
    result =
      %{
        "action" => "send_email_verification",
        "user_id" => user_id,
        "verification_url" => verification_url
      }
      |> new(
        queue: :emails,
        # Highest priority for auth emails
        priority: 0,
        unique: [
          # 2 minutes uniqueness window for auth emails
          period: 120,
          fields: [:args, :queue],
          keys: [:action, :user_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Email verification job scheduled", user_id: user_id)
        :ok

      {:error, %Ecto.Changeset{errors: [unique: _]}} ->
        Logger.info("Email verification job already exists, skipping duplicate",
          user_id: user_id
        )

        :ok

      {:error, changeset} ->
        Logger.error("Failed to schedule email verification",
          user_id: user_id,
          error: inspect(changeset)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules password reset email immediately with high priority.
  """
  @spec schedule_password_reset(term(), String.t()) :: :ok | {:error, String.t()}
  def schedule_password_reset(user_id, reset_url) do
    result =
      %{
        "action" => "send_password_reset",
        "user_id" => user_id,
        "reset_url" => reset_url
      }
      |> new(
        queue: :emails,
        # Highest priority for auth emails
        priority: 0,
        unique: [
          # 2 minutes uniqueness window
          period: 120,
          fields: [:args, :queue],
          keys: [:action, :user_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Password reset email job scheduled", user_id: user_id)
        :ok

      {:error, %Ecto.Changeset{errors: [unique: _]}} ->
        Logger.info("Password reset email job already exists, skipping duplicate",
          user_id: user_id
        )

        :ok

      {:error, changeset} ->
        Logger.error("Failed to schedule password reset email",
          user_id: user_id,
          error: inspect(changeset)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules reminder emails to be sent at a specific time with medium priority.
  If no scheduled_at is provided, defaults to 30 minutes before the meeting.
  """
  @spec schedule_reminder_emails(term(), DateTime.t() | nil) :: :ok | {:error, String.t()}
  def schedule_reminder_emails(meeting_id, scheduled_at \\ nil) do
    scheduled_at = scheduled_at || calculate_reminder_time(meeting_id)

    result =
      %{"action" => "send_reminder_emails", "meeting_id" => meeting_id}
      |> new(
        queue: :emails,
        # Medium priority for reminders
        priority: 2,
        scheduled_at: scheduled_at,
        unique: [
          # 1 hour uniqueness window for reminders
          period: 3600,
          fields: [:args, :queue],
          keys: [:action, :meeting_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Reminder email job scheduled",
          meeting_id: meeting_id,
          scheduled_at: scheduled_at
        )

        :ok

      {:error, %Ecto.Changeset{errors: [unique: _]}} ->
        Logger.info("Reminder email job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        # Return success since job already exists
        :ok

      {:error, changeset} ->
        Logger.error("Failed to schedule reminder emails",
          meeting_id: meeting_id,
          scheduled_at: scheduled_at,
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
        handle_email_error(error_type, job)

      {:discard, reason} ->
        {:discard, reason}

      _ ->
        handle_unexpected_email_result(result)
    end
  end

  defp handle_email_error(:rate_limited, job) do
    # Snooze for longer period when rate limited
    # Max 5 minutes
    snooze_seconds = min(300, 60 * job.attempt)

    Logger.warning("Email service rate limited, snoozing",
      snooze_seconds: snooze_seconds
    )

    {:snooze, snooze_seconds}
  end

  defp handle_email_error(:invalid_email, _job) do
    Logger.error("Invalid email address, discarding job")
    {:discard, "Invalid email address"}
  end

  defp handle_email_error(:meeting_not_found, _job) do
    Logger.error("Meeting not found, discarding job")
    {:discard, "Meeting not found"}
  end

  defp handle_email_error(:meeting_cancelled, _job) do
    Logger.info("Meeting cancelled, discarding job")
    {:discard, "Meeting cancelled"}
  end

  defp handle_email_error(reason, _job) when is_binary(reason) do
    # Generic error - retry with backoff
    {:error, reason}
  end

  defp handle_email_error(_reason, _job) do
    # Unknown error format - retry
    {:error, "Unknown error"}
  end

  defp handle_unexpected_email_result(result) do
    Logger.error("Unexpected result from email job", result: inspect(result))
    {:error, "Unexpected result"}
  end

  defp execute_email_job_with_timeout(action, args, job) do
    task = Task.async(fn -> EmailWorkerHandlers.execute_email_action(action, args) end)

    case Task.yield(task, @email_timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        handle_result(result, job)

      nil ->
        Logger.error("Email job timed out",
          action: action,
          timeout_ms: @email_timeout_ms,
          job_id: job.id,
          attempt: job.attempt
        )

        {:error, "Email sending timed out"}
    end
  end

  defp calculate_backoff(attempt) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s
    round(min(@backoff_base_ms * :math.pow(2, attempt - 1), 16_000))
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # convert ms to seconds for Oban backoff
    div(calculate_backoff(attempt), 1_000)
  end

  defp calculate_reminder_time(meeting_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        # Default to 30 minutes before the meeting
        DateTime.add(meeting.start_time, -30, :minute)

      {:error, :not_found} ->
        # Fallback to current time if meeting not found
        DateTime.utc_now()
    end
  end

  # Validate required fields based on action; reject malformed jobs early
  @spec changeset(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(changeset, args) when is_map(args) do
    required = required_fields_for_action(Map.get(args, "action"))
    missing = Enum.reject(required, &Map.has_key?(args, &1))

    if missing == [] do
      changeset
    else
      Changeset.add_error(
        changeset,
        :args,
        "missing required fields: #{Enum.join(missing, ", ")}"
      )
    end
  end

  @spec changeset(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def changeset(changeset, _args) do
    Changeset.add_error(changeset, :args, "args must be a map")
  end

  defp required_fields_for_action(action) do
    case action do
      "send_confirmation_emails" -> ["meeting_id"]
      "send_reminder_emails" -> ["meeting_id"]
      "send_reschedule_request" -> ["meeting_id"]
      "send_contact_form" -> ["sender_name", "sender_email", "subject", "message"]
      "send_email_verification" -> ["user_id", "verification_url"]
      "send_password_reset" -> ["user_id", "reset_url"]
      "send_email_change_verification" -> ["user_id", "new_email", "verification_url"]
      "send_email_change_notification" -> ["user_id", "new_email"]
      "send_email_change_confirmations" -> ["user_id", "old_email", "new_email"]
      nil -> ["action"]
      _ -> []
    end
  end
end
