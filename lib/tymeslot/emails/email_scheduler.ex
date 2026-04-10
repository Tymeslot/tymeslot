defmodule Tymeslot.Emails.EmailScheduler do
  @moduledoc """
  Schedules email delivery jobs via Oban.

  This module is the single point of entry for enqueueing email jobs. Each
  function validates its inputs, constructs the appropriate Oban job via
  `Tymeslot.Workers.EmailWorker.new/2`, and inserts it into the database.
  Uniqueness constraints on each job type prevent duplicate sends within the
  configured windows.

  ## Responsibilities

  - Scheduling confirmation, cancellation, and reminder emails for meetings
  - Scheduling authentication emails (verification, password reset, email change)
  - Scheduling integration health notifications and admin alert emails
  - Scheduling calendar invitation and event update notification emails

  Callers should reference this module directly — no delegation functions exist
  on `Tymeslot.Workers.EmailWorker`.
  """

  alias Ecto.Changeset
  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @type entity_with_id :: %{required(:id) => pos_integer(), optional(atom()) => term()}

  @doc """
  Schedules confirmation emails to be sent immediately with high priority.
  """
  @spec schedule_confirmation_emails(term()) :: :ok | {:error, String.t()}
  def schedule_confirmation_emails(meeting_id) do
    result =
      %{"action" => "send_confirmation_emails", "meeting_id" => meeting_id}
      |> EmailWorker.new(
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

      {:error, %Changeset{errors: [unique: _details]}} ->
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
      |> EmailWorker.new(
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

      {:error, %Changeset{errors: [unique: _details]}} ->
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
      |> EmailWorker.new(
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

      {:error, %Changeset{errors: [unique: _details]}} ->
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
      |> EmailWorker.new(
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

      {:error, %Changeset{errors: [unique: _details]}} ->
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
  If no `scheduled_at` is provided, defaults to the reminder interval before the meeting.
  """
  @spec schedule_reminder_emails(term(), term(), term(), DateTime.t() | nil) ::
          :ok | {:error, String.t()}
  def schedule_reminder_emails(meeting_id, reminder_value, reminder_unit, scheduled_at \\ nil) do
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
          |> EmailWorker.new(
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

          {:error, %Changeset{errors: [unique: _unique_error]}} ->
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
      |> EmailWorker.new(
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

      {:error, %Changeset{errors: [unique: _details]}} ->
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
      |> EmailWorker.new(
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

      {:error, %Changeset{errors: [unique: _details]}} ->
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

  @doc """
  Schedules an event update notification with a 2-minute delay.

  Uses Oban uniqueness (keyed on action + event_uid, 5-minute period) to
  coalesce rapid edits into a single notification.
  """
  @spec schedule_event_update_notification(map()) :: :ok | {:error, String.t()}
  def schedule_event_update_notification(params) do
    result =
      %{
        "action" => "send_event_update_notification",
        "user_id" => params.user_id,
        "event_uid" => params.event_uid,
        "integration_id" => params.integration_id,
        "attendee_emails" => params.attendee_emails,
        "before_title" => params.before_title,
        "before_location" => params.before_location,
        "before_description" => params.before_description,
        "before_start_at" =>
          params.before_start_at && DateTime.to_iso8601(params.before_start_at),
        "before_end_at" => params.before_end_at && DateTime.to_iso8601(params.before_end_at)
      }
      |> EmailWorker.new(
        queue: :emails,
        priority: 1,
        scheduled_at: DateTime.add(DateTime.utc_now(), 120, :second),
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: [:action, :event_uid]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Event update notification job scheduled",
          event_uid: params.event_uid,
          scheduled_in: "2 minutes"
        )

        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Event update notification job already pending, coalescing",
          event_uid: params.event_uid
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule event update notification",
          event_uid: params.event_uid,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules email change verification and notification emails.

  Enqueues two jobs: one to send a verification email to the new address,
  and one to notify the current address of the pending change. Both use a
  10-minute uniqueness window to prevent duplicate sends.
  """
  @spec schedule_email_change_emails(term(), String.t(), String.t()) :: :ok
  def schedule_email_change_emails(user_id, new_email, verification_url) do
    with {:ok, _job1} <-
           Oban.insert(
             EmailWorker.new(
               %{
                 "action" => "send_email_change_verification",
                 "user_id" => user_id,
                 "new_email" => new_email,
                 "verification_url" => verification_url
               },
               unique: [
                 period: 600,
                 fields: [:args, :queue],
                 keys: [:action, :user_id, :new_email, :verification_url]
               ]
             )
           ),
         {:ok, _job2} <-
           Oban.insert(
             EmailWorker.new(
               %{
                 "action" => "send_email_change_notification",
                 "user_id" => user_id,
                 "new_email" => new_email
               },
               unique: [
                 period: 600,
                 fields: [:args, :queue],
                 keys: [:action, :user_id, :new_email]
               ]
             )
           ) do
      :ok
    else
      error ->
        Logger.error("Failed to enqueue email change emails",
          error: inspect(error),
          user_id: user_id
        )

        :ok
    end
  end

  @doc """
  Schedules confirmation emails after a successful email change.

  Enqueues a job to send confirmations to both the old and new email
  addresses. Uses a 1-hour uniqueness window.
  """
  @spec schedule_email_change_confirmations(term(), String.t(), String.t()) :: :ok
  def schedule_email_change_confirmations(user_id, old_email, new_email) do
    case Oban.insert(
           EmailWorker.new(
             %{
               "action" => "send_email_change_confirmations",
               "user_id" => user_id,
               "old_email" => old_email,
               "new_email" => new_email
             },
             unique: [
               period: 3600,
               fields: [:args, :queue],
               keys: [:action, :user_id, :old_email, :new_email]
             ]
           )
         ) do
      {:ok, _job} ->
        :ok

      error ->
        Logger.error("Failed to enqueue email change confirmations",
          error: inspect(error),
          user_id: user_id
        )

        :ok
    end
  end

  @doc """
  Schedules a reschedule request email to be sent to the attendee.
  """
  @spec schedule_reschedule_request(term()) :: :ok | {:error, term()}
  def schedule_reschedule_request(meeting_id) do
    job_params = %{
      "action" => "send_reschedule_request",
      "meeting_id" => meeting_id
    }

    case Oban.insert(EmailWorker.new(job_params, queue: :emails, priority: 1)) do
      {:ok, _job} ->
        Logger.info("Reschedule request email job queued", meeting_id: meeting_id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to queue reschedule request email",
          meeting_id: meeting_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Schedules an administrative alert email.

  Delegates to `Tymeslot.Workers.EmailWorker.AdminAlertScheduler.schedule/5`,
  which handles dedup via Oban's uniqueness constraint (24-hour window keyed on
  recipient + category + message hash).
  """
  @spec schedule_admin_alert(
          recipient :: String.t(),
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map()
        ) :: :ok | {:error, String.t()}
  defdelegate schedule_admin_alert(recipient, category, severity, message, metadata),
    to: Tymeslot.Workers.EmailWorker.AdminAlertScheduler,
    as: :schedule

  # --- Changeset validation (used by EmailWorker's Oban callback) ---

  @fields_by_action %{
    "send_confirmation_emails" => ["meeting_id"],
    "send_cancellation_emails" => ["meeting_id"],
    "send_reminder_emails" => ["meeting_id", "reminder_value", "reminder_unit"],
    "send_reschedule_request" => ["meeting_id"],
    "send_email_verification" => ["user_id", "verification_url"],
    "send_password_reset" => ["user_id", "reset_url"],
    "send_email_change_verification" => ["user_id", "new_email", "verification_url"],
    "send_email_change_notification" => ["user_id", "new_email"],
    "send_email_change_confirmations" => ["user_id", "old_email", "new_email"],
    "send_integration_unhealthy_notification" => [
      "user_id",
      "integration_id",
      "integration_type"
    ],
    "send_calendar_invitation" => [
      "user_id",
      "attendee_email",
      "event_title",
      "event_uid",
      "event_start_at",
      "event_end_at"
    ],
    "send_event_update_notification" => [
      "user_id",
      "event_uid",
      "integration_id",
      "attendee_emails",
      "before_title",
      "before_location",
      "before_description",
      "before_start_at",
      "before_end_at"
    ],
    "send_admin_alert" => [
      "recipient",
      "category",
      "severity",
      "message",
      "metadata",
      "alert_hash"
    ]
  }

  @doc """
  Validates required fields for an Oban job changeset based on the action.

  Called by `Tymeslot.Workers.EmailWorker.changeset/2` to keep validation
  logic co-located with the scheduling functions that define the argument
  shapes.
  """
  @spec validate_args(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def validate_args(changeset, args) when is_map(args) do
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

  @spec validate_args(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def validate_args(changeset, _args) do
    Changeset.add_error(changeset, :args, "args must be a map")
  end

  # Private helpers

  defp required_fields_for_action(nil), do: ["action"]
  defp required_fields_for_action(action), do: Map.get(@fields_by_action, action, [])

  defp format_insert_error(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  defp format_insert_error(other), do: inspect(other)

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
    ObanJobQueries.delete_reminder_jobs_for_meeting(
      meeting_id,
      to_string(EmailWorker),
      %{"reminder_value" => reminder_value, "reminder_unit" => reminder_unit}
    )
  end
end
