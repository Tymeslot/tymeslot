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

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.EmailWorkerHandlers
  require Logger

  @type entity_with_id :: %{required(:id) => pos_integer(), optional(atom()) => term()}

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
  def perform(%Oban.Job{args: %{"action" => action} = args, attempt: attempt} = job) do
    Logger.metadata(job_id: job.id, attempt: attempt)
    if user_id = args["user_id"], do: Logger.metadata(user_id: user_id)

    execute_email_job_with_timeout(action, args, job)
  end

  def perform(%Oban.Job{args: args, attempt: attempt} = job) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    Logger.error("EmailWorker job missing action parameter",
      arg_keys: Map.keys(args)
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

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.info("Confirmation email job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        # Return success since job already exists
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule confirmation emails",
          meeting_id: meeting_id,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules cancellation emails to be sent immediately with high priority.
  """
  @spec schedule_cancellation_emails(term()) :: :ok | {:error, String.t()}
  def schedule_cancellation_emails(meeting_id) do
    result =
      %{"action" => "send_cancellation_emails", "meeting_id" => meeting_id}
      |> new(
        queue: :emails,
        # Highest priority for cancellations
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
        Logger.info("Cancellation email job scheduled", meeting_id: meeting_id)
        :ok

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.info("Cancellation email job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule cancellation emails",
          meeting_id: meeting_id,
          error: format_insert_error(reason)
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

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.info("Email verification job already exists, skipping duplicate",
          user_id: user_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule email verification",
          user_id: user_id,
          error: format_insert_error(reason)
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

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.info("Password reset email job already exists, skipping duplicate",
          user_id: user_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule password reset email",
          user_id: user_id,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules reminder emails to be sent at a specific time with medium priority.
  If no scheduled_at is provided, defaults to the reminder interval before the meeting.
  """
  @spec schedule_reminder_emails(term(), term(), term(), DateTime.t() | nil) ::
          :ok | {:error, String.t()}
  def schedule_reminder_emails(meeting_id, reminder_value, reminder_unit, scheduled_at \\ nil) do
    # Ensure atomic keys and normalized values
    case ReminderUtils.normalize_reminder(%{value: reminder_value, unit: reminder_unit}) do
      {:ok, %{value: value, unit: unit}} ->
        scheduled_at =
          scheduled_at || calculate_reminder_time(meeting_id, value, unit)

        _deleted = delete_existing_reminder_jobs(meeting_id, value, unit)

        result =
          %{
            "action" => "send_reminder_emails",
            "meeting_id" => meeting_id,
            "reminder_value" => value,
            "reminder_unit" => unit
          }
          |> new(
            queue: :emails,
            # Medium priority for reminders
            priority: 2,
            scheduled_at: scheduled_at,
            unique: [
              # Prevent duplicate reminders across long lead times (10 years in seconds)
              period: 315_360_000,
              fields: [:args, :queue],
              keys: [:action, :meeting_id, :reminder_value, :reminder_unit]
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

          {:error, %Ecto.Changeset{errors: [unique: _unique_error]}} ->
            Logger.info("Reminder email job already exists, skipping duplicate",
              meeting_id: meeting_id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to schedule reminder emails",
              meeting_id: meeting_id,
              error: format_insert_error(reason)
            )

            {:error, "Failed to schedule job"}
        end

      _error ->
        {:error, "invalid_reminder"}
    end
  end

  @doc """
  Schedules an integration unhealthy notification email with medium priority.

  Uses a 30-day uniqueness window per user + integration + type so that a
  re-occurring flap does not immediately re-send after a cooldown expires.
  The ResponseHandler also tracks `notification_sent_at` in the DB for the same
  reason; the Oban uniqueness is a belt-and-suspenders safeguard.
  """
  @spec schedule_integration_unhealthy_notification(
          entity_with_id(),
          entity_with_id(),
          atom() | String.t()
        ) :: :ok | {:error, String.t()}
  def schedule_integration_unhealthy_notification(user, integration, type) do
    result =
      %{
        "action" => "send_integration_unhealthy_notification",
        "user_id" => user.id,
        "integration_id" => integration.id,
        "integration_type" => to_string(type)
      }
      |> new(
        queue: :emails,
        priority: 2,
        unique: [
          # 30-day uniqueness to match the notification cooldown
          period: 30 * 24 * 60 * 60,
          fields: [:args, :queue],
          keys: [:action, :user_id, :integration_id, :integration_type]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Integration unhealthy notification job scheduled",
          user_id: user.id,
          integration_id: integration.id,
          type: type
        )

        :ok

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.info("Integration unhealthy notification job already exists, skipping duplicate",
          user_id: user.id,
          integration_id: integration.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule integration unhealthy notification",
          user_id: user.id,
          integration_id: integration.id,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules a calendar invitation email with high priority.

  Takes a map with atom keys containing event details and the organiser's user ID.
  DateTimes are passed as ISO 8601 strings for JSON serialisation.
  """
  @spec schedule_calendar_invitation(map()) :: :ok | {:error, String.t()}
  def schedule_calendar_invitation(params) do
    result =
      %{
        "action" => "send_calendar_invitation",
        "user_id" => params.user_id,
        "attendee_email" => params.attendee_email,
        "event_title" => params.event_title,
        "event_uid" => params.event_uid,
        "event_start_at" => params.event_start_at,
        "event_end_at" => params.event_end_at,
        "event_location" => params[:event_location],
        "event_description" => params[:event_description]
      }
      |> new(
        queue: :emails,
        priority: 0,
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: [:action, :attendee_email, :event_uid]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Calendar invitation email job scheduled",
          user_id: params.user_id,
          attendee_email: params.attendee_email,
          event_uid: params.event_uid
        )

        :ok

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.info("Calendar invitation email job already exists, skipping duplicate",
          attendee_email: params.attendee_email,
          event_uid: params.event_uid
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar invitation email",
          user_id: params.user_id,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
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
        handle_email_error(error_type, job)

      {:discard, reason} ->
        {:discard, reason}

      _other ->
        handle_unexpected_email_result(result)
    end
  end

  defp handle_email_error(:rate_limited, %{attempt: attempt}) do
    # Snooze for longer period when rate limited
    # Max 5 minutes
    snooze_seconds = min(300, 60 * attempt)

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

  defp handle_email_error(_other_reason, _job) do
    # Unknown error format - retry
    {:error, "Unknown error"}
  end

  defp handle_unexpected_email_result(result) do
    Logger.error("Unexpected result from email job", result: result)
    {:error, "Unexpected result"}
  end

  defp execute_email_job_with_timeout(action, args, job) do
    task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        EmailWorkerHandlers.execute_email_action(action, args)
      end)

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

  defp calculate_reminder_time(meeting_id, reminder_value, reminder_unit) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        seconds = ReminderUtils.reminder_interval_seconds(reminder_value, reminder_unit)
        DateTime.add(meeting.start_time, -seconds, :second)

      {:error, :not_found} ->
        # Fallback to current time if meeting not found
        DateTime.utc_now()
    end
  end

  defp delete_existing_reminder_jobs(meeting_id, reminder_value, reminder_unit) do
    worker_str = to_string(__MODULE__)

    args_match = %{
      "action" => "send_reminder_emails",
      "meeting_id" => meeting_id,
      "reminder_value" => reminder_value,
      "reminder_unit" => reminder_unit
    }

    Repo.delete_all(
      from(j in Job,
        where: j.queue == "emails",
        where: j.worker == ^worker_str,
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("? @> ?::jsonb", j.args, type(^args_match, :map))
      )
    )
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
      "send_confirmation_emails" ->
        ["meeting_id"]

      "send_cancellation_emails" ->
        ["meeting_id"]

      "send_reminder_emails" ->
        ["meeting_id", "reminder_value", "reminder_unit"]

      "send_reschedule_request" ->
        ["meeting_id"]

      "send_email_verification" ->
        ["user_id", "verification_url"]

      "send_password_reset" ->
        ["user_id", "reset_url"]

      "send_email_change_verification" ->
        ["user_id", "new_email", "verification_url"]

      "send_email_change_notification" ->
        ["user_id", "new_email"]

      "send_email_change_confirmations" ->
        ["user_id", "old_email", "new_email"]

      "send_integration_unhealthy_notification" ->
        ["user_id", "integration_id", "integration_type"]

      "send_calendar_invitation" ->
        [
          "user_id",
          "attendee_email",
          "event_title",
          "event_uid",
          "event_start_at",
          "event_end_at"
        ]

      nil ->
        ["action"]

      _other_action ->
        []
    end
  end
end
