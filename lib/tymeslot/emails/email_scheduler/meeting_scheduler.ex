defmodule Tymeslot.Emails.EmailScheduler.MeetingScheduler do
  @moduledoc "Schedules meeting-related emails via Oban."

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.EmailWorker

  require Logger

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
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules the pair of emails a held booking produces: the invitee's
  acknowledgement and the host's request to answer.

  One job sends both, so an invitee cannot be told their request is with the
  host while the host's copy fails independently.
  """
  @spec schedule_request_emails(term()) :: :ok | {:error, String.t()}
  def schedule_request_emails(meeting_id) do
    %{"action" => "send_booking_request_emails", "meeting_id" => meeting_id}
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [period: 300, fields: [:args, :queue], keys: [:action, :meeting_id]]
    )
    |> insert_job("Booking request emails", meeting_id)
  end

  @doc """
  Schedules the single reminder sent to a host who has not yet answered.

  Fires at `send_at`, halfway through the approval window. Uniqueness is keyed
  on the meeting alone with a ten-year period, so a reschedule that re-enters
  the gate cannot stack a second nudge on the first; the deletion in
  `cancel_approval_emails/1` is what allows a genuinely new one.
  """
  @spec schedule_approval_nudge(term(), DateTime.t()) :: :ok | {:error, String.t()}
  def schedule_approval_nudge(meeting_id, %DateTime{} = send_at) do
    delete_existing_approval_jobs(meeting_id)

    %{"action" => "send_booking_approval_nudge", "meeting_id" => meeting_id}
    |> EmailWorker.new(
      queue: :emails,
      priority: 1,
      scheduled_at: send_at,
      unique: [period: 315_360_000, fields: [:args, :queue], keys: [:action, :meeting_id]]
    )
    |> insert_job("Approval nudge", meeting_id)
  end

  @doc """
  Deletes any pending nudge for a meeting.

  Called on every exit from the approval gate. A nudge that fires after the
  host has already answered would ask them to decide something they decided.
  """
  @spec cancel_approval_emails(term()) :: :ok
  def cancel_approval_emails(meeting_id) do
    delete_existing_approval_jobs(meeting_id)
    :ok
  end

  defp delete_existing_approval_jobs(meeting_id) do
    ObanJobQueries.delete_jobs_by_action(
      EmailWorker,
      "send_booking_approval_nudge",
      meeting_id
    )
  end

  # Shared insert-and-report used by the approval jobs. A unique-conflict is
  # success: the job we wanted already exists.
  defp insert_job(changeset, label, meeting_id) do
    case Oban.insert(changeset) do
      {:ok, _job} ->
        Logger.info("Approval email job scheduled", meeting_id: meeting_id, email_job: label)
        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Approval email job already exists, skipping duplicate",
          meeting_id: meeting_id,
          email_job: label
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule approval email job",
          meeting_id: meeting_id,
          email_job: label,
          error: Helpers.format_insert_error(reason)
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
          error: Helpers.format_insert_error(reason)
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
              error: Helpers.format_insert_error(reason)
            )

            {:error, "Failed to schedule job"}
        end

      _error ->
        {:error, "invalid_reminder"}
    end
  end

  @doc """
  Deletes all pending reminder email jobs for a meeting.

  Used when the meeting's scheduled time stops being valid — cancellation or
  an organizer reschedule request — so no reminder fires for a void time slot.
  """
  @spec cancel_reminder_emails(term()) :: :ok
  def cancel_reminder_emails(meeting_id) do
    {deleted, _result} =
      ObanJobQueries.delete_reminder_jobs_for_meeting(meeting_id, EmailWorker, %{})

    Logger.info("Cancelled pending reminder email jobs",
      meeting_id: meeting_id,
      deleted_count: deleted
    )

    :ok
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

  # Private helpers

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
      EmailWorker,
      %{"reminder_value" => reminder_value, "reminder_unit" => reminder_unit}
    )
  end
end
