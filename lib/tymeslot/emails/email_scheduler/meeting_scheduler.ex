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
  Schedules a single-seat email job.

  One job per `(action, meeting_id, participant_id)`, uniqued on that triple
  within a 5-minute window — the shared shape behind every per-seat email
  action (confirmation, cancellation, reschedule, and the whole-meeting
  cancellation/reminder/reschedule-request fan-outs), so each recipient
  retries independently of the others and a different action for the same
  participant can never collide with this one. `extra_args` carries whatever
  the action needs beyond the two ids (e.g. `notify_organizer`, the old-event
  snapshot, or the reminder interval).
  """
  @spec schedule_seat_email(String.t(), term(), term(), map()) :: :ok | {:error, String.t()}
  def schedule_seat_email(action, meeting_id, participant_id, extra_args \\ %{}) do
    result =
      extra_args
      |> Map.merge(%{
        "action" => action,
        "meeting_id" => meeting_id,
        "participant_id" => participant_id
      })
      |> EmailWorker.new(
        queue: :emails,
        priority: 0,
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: [:action, :meeting_id, :participant_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Seat email job scheduled",
          action: action,
          meeting_id: meeting_id,
          participant_id: participant_id
        )

        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule seat email",
          action: action,
          meeting_id: meeting_id,
          participant_id: participant_id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules the confirmation emails for a single group-booking seat.
  """
  @spec schedule_seat_confirmation_emails(term(), term()) :: :ok | {:error, String.t()}
  def schedule_seat_confirmation_emails(meeting_id, participant_id),
    do: schedule_seat_email("send_seat_confirmation_emails", meeting_id, participant_id)

  @doc """
  Schedules the cancellation emails for a single group-booking seat.
  """
  @spec schedule_seat_cancellation_emails(term(), term(), boolean()) ::
          :ok | {:error, String.t()}
  def schedule_seat_cancellation_emails(meeting_id, participant_id, notify_organizer?) do
    schedule_seat_email("send_seat_cancellation_emails", meeting_id, participant_id, %{
      "notify_organizer" => notify_organizer?
    })
  end

  @doc """
  Schedules the reschedule emails for a single group-booking seat.

  `old_snapshot` carries the old event's identity (`uid`, `ical_sequence`,
  `start_time`, `end_time`) so the email job can build the cancel ICS even
  after the old meeting row changes.
  """
  @spec schedule_seat_reschedule_emails(term(), term(), map()) :: :ok | {:error, String.t()}
  def schedule_seat_reschedule_emails(meeting_id, participant_id, old_snapshot) do
    schedule_seat_email("send_seat_reschedule_emails", meeting_id, participant_id, %{
      "old_uid" => old_snapshot.uid,
      "old_ical_sequence" => old_snapshot.ical_sequence,
      "old_start_time" => DateTime.to_iso8601(old_snapshot.start_time),
      "old_end_time" => DateTime.to_iso8601(old_snapshot.end_time)
    })
  end

  @doc """
  Schedules one live participant's copy of a whole-meeting cancellation.

  Dispatched (one call per live participant) from the meeting-level
  cancellation job instead of sending inline, so a failure on one participant
  cannot discard the notification to the rest.
  """
  @spec schedule_seat_meeting_cancellation_email(term(), term()) :: :ok | {:error, String.t()}
  def schedule_seat_meeting_cancellation_email(meeting_id, participant_id),
    do: schedule_seat_email("send_seat_meeting_cancellation", meeting_id, participant_id)

  @doc """
  Schedules one live participant's reminder.

  Dispatched (one call per live participant) from the meeting-level reminder
  job instead of sending inline, so a failure on one participant cannot
  discard the reminder to the rest.
  """
  @spec schedule_seat_reminder_email(term(), term(), term(), term()) ::
          :ok | {:error, String.t()}
  def schedule_seat_reminder_email(meeting_id, participant_id, reminder_value, reminder_unit) do
    schedule_seat_email("send_seat_reminder", meeting_id, participant_id, %{
      "reminder_value" => reminder_value,
      "reminder_unit" => reminder_unit
    })
  end

  @doc """
  Schedules one live participant's reschedule request.

  Dispatched (one call per live participant) from the meeting-level
  reschedule-request job instead of sending inline, so a failure on one
  participant cannot discard the request to the rest.
  """
  @spec schedule_seat_reschedule_request(term(), term()) :: :ok | {:error, String.t()}
  def schedule_seat_reschedule_request(meeting_id, participant_id),
    do: schedule_seat_email("send_seat_reschedule_request", meeting_id, participant_id)

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
