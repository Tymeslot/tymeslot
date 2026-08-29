defmodule Tymeslot.Workers.VideoRoom.Recovery do
  @moduledoc """
  The long-tail recovery policy for video room creation.

  Ordinary retries are Oban's business: exponential backoff over the first few
  attempts, which covers a blip at the video provider. Past that the question
  stops being "retry sooner or later" and becomes "is there still time to get a
  join link in front of the attendees before they need it". That answer depends
  on the meeting rather than on the job, so it lives here rather than in the
  worker.

  ## The deadline is the earliest reminder, not the meeting start

  Reminder emails carry the join link, so a link written after the reminder went
  out is already too late even though the meeting has not started. The deadline
  is therefore the earliest reminder that will fire, falling back to the meeting
  start when a meeting has none, minus a small buffer so a reminder rendering at
  the same moment still picks the link up.

  Reminders come from the meeting when it carries its own, otherwise from its
  meeting type's configuration.

  ## Attempts are spread across the time that is left

  Rather than a fixed interval, each remaining attempt takes an even share of
  the time still available. A meeting an hour away is retried on a much tighter
  cadence than one three days out, and neither burns through its attempts early
  nor waits past its own deadline.
  """

  alias Tymeslot.Meetings.{MeetingQueries, MeetingSchema}
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Utils.ReminderUtils

  require Logger

  # Attempts spent on ordinary retries before recovery takes over. The fallback
  # emails (without a join link) go out on exactly this attempt, once.
  @fallback_attempt 5

  # Recovery snoozes allowed after the fallback threshold.
  @max_attempts 5

  # Have the link written this long before the deadline, so a reminder rendering
  # at the same moment still picks it up.
  @cutoff_buffer_seconds 300

  @typedoc "An Oban `perform/1` return value."
  @type decision :: {:snooze, pos_integer()} | {:discard, String.t()}

  @doc """
  Whether this attempt has exhausted ordinary retries and entered recovery.

  Recovery only applies to jobs that owe the attendees an email. A job created
  without `send_emails` has no deadline to race, so it simply retries and gives
  up on Oban's own schedule.
  """
  @spec recovering?(pos_integer(), boolean()) :: boolean()
  def recovering?(attempt, send_emails), do: send_emails and attempt >= @fallback_attempt

  @doc """
  Enters recovery for a meeting and returns the resulting Oban decision.

  On the first recovery attempt this also sends the confirmation emails without
  a join link, so the attendees are not left waiting on an email that may never
  come. `cause` is logged to distinguish a failing provider from a hanging one.
  """
  @spec enter(String.t(), pos_integer(), String.t()) :: decision()
  def enter(meeting_id, attempt, cause) do
    if attempt == @fallback_attempt do
      Logger.warning("Video room creation entering recovery, announcing without a room",
        meeting_id: meeting_id,
        attempts: @fallback_attempt,
        cause: cause
      )

      send_fallback_notifications(meeting_id)
    end

    decide(meeting_id, attempt - @fallback_attempt + 1)
  end

  @doc """
  Announces the meeting without a video room link.

  Used both on entering recovery and when the failure is already known to be
  unrecoverable, so the attendees still receive their confirmation and anything
  subscribed to `meeting.created` still learns about the booking.
  """
  @spec send_fallback_notifications(String.t()) :: :ok
  def send_fallback_notifications(meeting_id) do
    Logger.info("Announcing the meeting without a video room after creation failed",
      meeting_id: meeting_id
    )

    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        Events.meeting_created(meeting)
        :ok

      {:error, _reason} ->
        Logger.error("Could not fetch meeting for fallback email scheduling",
          meeting_id: meeting_id
        )

        :ok
    end
  end

  @doc """
  The snooze before the next recovery attempt, spreading the remaining attempts
  evenly across the time left before the deadline.

  Returns `{:error, :deadline_passed}` once there is no longer enough time to be
  useful, which the caller turns into a discard.
  """
  @spec snooze_seconds(MeetingSchema.t(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :deadline_passed}
  def snooze_seconds(meeting, recovery_attempt, max_attempts \\ @max_attempts) do
    time_left =
      DateTime.diff(deadline(meeting), DateTime.utc_now()) - @cutoff_buffer_seconds

    if time_left <= 0 do
      {:error, :deadline_passed}
    else
      remaining_attempts = max(max_attempts - recovery_attempt + 1, 1)
      {:ok, max(div(time_left, remaining_attempts), 1)}
    end
  end

  @doc """
  The moment by which the join link must exist: the earliest reminder that will
  fire, or the meeting start when there are no reminders.
  """
  @spec deadline(MeetingSchema.t()) :: DateTime.t()
  def deadline(meeting) do
    case reminders(meeting) do
      [] -> meeting.start_time
      list -> DateTime.add(meeting.start_time, -earliest_offset(list, meeting), :second)
    end
  end

  defp decide(_meeting_id, recovery_attempt) when recovery_attempt > @max_attempts,
    do: {:discard, "Recovery attempts exhausted"}

  defp decide(meeting_id, recovery_attempt) do
    with {:ok, meeting} <- MeetingQueries.get_meeting(meeting_id),
         :gt <- DateTime.compare(meeting.start_time, DateTime.utc_now()),
         {:ok, seconds} <- snooze_seconds(meeting, recovery_attempt) do
      {:snooze, seconds}
    else
      {:error, :not_found} -> {:discard, "Meeting not found"}
      {:error, :deadline_passed} -> {:discard, "Recovery deadline passed"}
      _started -> {:discard, "Meeting already started"}
    end
  end

  # A meeting's own reminders win; otherwise fall back to its type's configured
  # ones. Either may legitimately be absent, leaving the meeting start as the
  # only deadline.
  defp reminders(%{reminders: list}) when is_list(list) and list != [], do: list

  defp reminders(%{meeting_type_id: nil}), do: []

  defp reminders(meeting) do
    case MeetingTypeQueries.get_meeting_type_t(meeting.meeting_type_id, meeting.organizer_user_id) do
      {:ok, %{reminder_config: config}} when is_list(config) and config != [] -> config
      _none -> []
    end
  end

  # The earliest reminder is the one furthest ahead of the meeting, so the
  # largest offset wins. A reminder stored in a shape this cannot read is worth
  # a warning but not a crashed job, so it counts as zero and the others decide.
  defp earliest_offset(reminders, meeting) do
    reminders
    |> Enum.map(&offset_seconds(&1, meeting))
    |> Enum.max()
  end

  defp offset_seconds(reminder, meeting) do
    value = Map.get(reminder, :value) || Map.get(reminder, "value")
    unit = Map.get(reminder, :unit) || Map.get(reminder, "unit")

    try do
      ReminderUtils.reminder_interval_seconds(value, unit)
    rescue
      exception ->
        Logger.warning("Ignoring unreadable reminder interval",
          meeting_id: meeting.id,
          value: inspect(value),
          unit: inspect(unit),
          error: Exception.message(exception)
        )

        0
    end
  end
end
