defmodule Tymeslot.Emails.EmailScheduler.MeetingScheduler do
  @moduledoc "Schedules meeting-related emails via Oban."

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs
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
      {:ok, %{conflict?: true}} ->
        Logger.info("Confirmation email job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        :ok

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

  # Canonical seat-email action names, declared once so the same six strings
  # aren't retyped at each call site here, in `EmailWorkerHandlers`'s
  # dispatch table, and in `Tymeslot.Emails.EmailScheduler`'s arg-validation
  # table. `:seat_cancellation` (a seat's own cancellation) and
  # `:seat_meeting_cancellation` (a live participant's copy of a *whole
  # meeting's* cancellation) are deliberately similar strings for genuinely
  # different actions — exactly the kind of near-collision a mistyped copy
  # could silently miss, so callers key off the atom instead.
  @spec seat_action(atom()) :: String.t()
  def seat_action(:seat_confirmation), do: "send_seat_confirmation_emails"
  def seat_action(:seat_cancellation), do: "send_seat_cancellation_emails"
  def seat_action(:seat_meeting_cancellation), do: "send_seat_meeting_cancellation"
  def seat_action(:seat_reschedule), do: "send_seat_reschedule_emails"
  def seat_action(:seat_reschedule_request), do: "send_seat_reschedule_request"
  def seat_action(:seat_reminder), do: "send_seat_reminder"

  @doc """
  Schedules a single-seat email job.

  One job per `(action, meeting_id, participant_id)`, uniqued on that triple
  — the shared shape behind every per-seat email action (confirmation,
  cancellation, reschedule, and the whole-meeting
  cancellation/reminder/reschedule-request fan-outs), so each recipient
  retries independently of the others and a different action for the same
  participant can never collide with this one. `extra_args` carries whatever
  the action needs beyond the two ids (e.g. `notify_organizer`, the old-event
  snapshot, or the reminder interval).

  The uniqueness window is wider than the usual 5 minutes deliberately: a
  seat job that hits an open mail circuit breaker snoozes for the breaker's
  recovery window plus jitter (up to ~330 seconds — see
  `Tymeslot.Workers.TransactionalEmailDelivery`), and a meeting-level
  dispatcher retried after its own circuit-open snooze re-runs this function
  for every participant again. A 5-minute window would have already elapsed
  by the time either of those wake up, so the just-inserted (or just
  completed) per-seat job would no longer read as a duplicate and this would
  insert a second one — re-sending to a participant who already got their
  email instead of the harmless no-op re-dispatch is meant to be.
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
          # 1 hour — comfortably past the ~330s worst-case circuit-open
          # snooze on either the seat job itself or the meeting-level
          # dispatcher that re-runs this. See the moduledoc above.
          period: 3600,
          fields: [:args, :queue],
          keys: [:action, :meeting_id, :participant_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, %{conflict?: true}} ->
        Logger.info("Seat email job already exists, skipping duplicate",
          action: action,
          meeting_id: meeting_id,
          participant_id: participant_id
        )

        :ok

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
    do: schedule_seat_email(seat_action(:seat_confirmation), meeting_id, participant_id)

  @doc """
  Schedules the cancellation emails for a single group-booking seat.
  """
  @spec schedule_seat_cancellation_emails(term(), term(), boolean()) ::
          :ok | {:error, String.t()}
  def schedule_seat_cancellation_emails(meeting_id, participant_id, notify_organizer?) do
    schedule_seat_email(seat_action(:seat_cancellation), meeting_id, participant_id, %{
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
    schedule_seat_email(seat_action(:seat_reschedule), meeting_id, participant_id, %{
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
    do: schedule_seat_email(seat_action(:seat_meeting_cancellation), meeting_id, participant_id)

  @doc """
  Schedules one live participant's reminder.

  Dispatched (one call per live participant) from the meeting-level reminder
  job instead of sending inline, so a failure on one participant cannot
  discard the reminder to the rest.
  """
  @spec schedule_seat_reminder_email(term(), term(), term(), term()) ::
          :ok | {:error, String.t()}
  def schedule_seat_reminder_email(meeting_id, participant_id, reminder_value, reminder_unit) do
    schedule_seat_email(seat_action(:seat_reminder), meeting_id, participant_id, %{
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
    do: schedule_seat_email(seat_action(:seat_reschedule_request), meeting_id, participant_id)

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
      {:ok, %{conflict?: true}} ->
        Logger.info("Cancellation email job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        :ok

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
              # Prevent duplicate reminders across long lead times (10 years in seconds).
              # Restricted to :incomplete states (excludes completed/cancelled/discarded) so
              # that a reminder which already fired never blocks a reschedule from enqueueing
              # a fresh one for the new time.
              period: 315_360_000,
              fields: [:args, :queue],
              keys: [:action, :meeting_id, :reminder_value, :reminder_unit],
              states: :incomplete
            ]
          )
          |> Oban.insert()

        case result do
          {:ok, %{conflict?: true}} ->
            Logger.info("Reminder email job already exists, skipping duplicate",
              meeting_id: meeting_id
            )

            :ok

          {:ok, _job} ->
            Logger.info("Reminder email job scheduled",
              meeting_id: meeting_id,
              scheduled_at: scheduled_at
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
      Jobs.delete_reminder_jobs_for_meeting(meeting_id, EmailWorker, %{})

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
    Jobs.delete_reminder_jobs_for_meeting(
      meeting_id,
      EmailWorker,
      %{"reminder_value" => reminder_value, "reminder_unit" => reminder_unit}
    )
  end
end
