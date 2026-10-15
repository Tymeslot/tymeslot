defmodule Tymeslot.Workers.EmailWorkerHandlers.SeatJobs do
  @moduledoc """
  The liveness check every per-seat email job of a group meeting makes
  before it sends anything.

  A seat job is scheduled at one moment and runs at another: after a retry,
  a circuit-open snooze, or simply behind a queue. In between the host can
  cancel the meeting or ask everyone to move, and the participant can cancel
  or move their seat. Each job therefore re-reads the meeting and the
  participant when it runs and states what it needs of both:

    * the meeting: `:live_slot` (not cancelled, and its time still holds),
      `:not_cancelled`, `:cancelled` (the copy of a whole-meeting
      cancellation), or `:any` (a participant's own cancellation, which is
      owed to them even when their leaving cancelled the meeting);
    * the participant: `:live` (still holds the seat), `:cancelled` (the
      seat's own cancellation, which needs it to have actually happened), or
      `:any` (a job that decides for itself, as a seat move does: the old
      seat's cancellation is owed whatever has become of the new one).

  A job whose seat no longer qualifies is discarded with a reason
  `expected_discard?/1` recognises: it is the normal end of a job overtaken
  by events, not a fault.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  @meeting_cancelled "Meeting cancelled"
  @meeting_not_cancelled "Meeting not cancelled"
  @slot_void "Meeting time no longer holds"
  @participant_gone "Participant not found or cancelled"
  @participant_not_cancelled "Participant still holds their seat"

  @type meeting_rule :: :live_slot | :not_cancelled | :cancelled | :any
  @type participant_rule :: :live | :cancelled | :any

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do:
      reason in [
        @meeting_cancelled,
        @meeting_not_cancelled,
        @slot_void,
        @participant_gone,
        @participant_not_cancelled
      ]

  @doc """
  Runs `fun` with the meeting and participant when both still qualify under
  `{meeting_rule, participant_rule}`, or discards the job, logging why.
  `action` names the email for the log line.
  """
  @spec with_seat(
          term(),
          term(),
          String.t(),
          {meeting_rule(), participant_rule()},
          (MeetingSchema.t(), ParticipantSchema.t() -> result)
        ) :: result | {:discard, String.t()}
        when result: term()
  def with_seat(meeting_id, participant_id, action, {meeting_rule, participant_rule}, fun) do
    MeetingEmails.with_meeting(meeting_id, action, fn meeting ->
      with :ok <- check_meeting(meeting, meeting_rule),
           {:ok, participant} <- fetch_participant(meeting, participant_id, participant_rule) do
        fun.(meeting, participant)
      else
        {:discard, reason} = discard ->
          Logger.info("Skipping seat email overtaken by events",
            email_action: action,
            meeting_id: meeting_id,
            participant_id: participant_id,
            reason: reason
          )

          discard
      end
    end)
  end

  @doc """
  The result of one send to one recipient, as a job outcome: `:ok`, or the
  failure logged and handed to `DeliveryOutcome.from_error/2`, so an open
  circuit snoozes and a dead address discards.
  """
  @spec send_result({:ok, term()} | {:error, term()}, String.t(), keyword()) ::
          :ok | {:error, term()}
  def send_result({:ok, _result}, _label, _metadata), do: :ok

  def send_result({:error, reason}, label, metadata) do
    Logger.error(
      "Failed to send seat email",
      metadata ++ [label: label, error: LogFormat.reason(reason)]
    )

    DeliveryOutcome.from_error(reason, "Failed to send seat #{label} email")
  end

  defp check_meeting(%{status: "cancelled"}, rule) when rule in [:live_slot, :not_cancelled],
    do: {:discard, @meeting_cancelled}

  defp check_meeting(meeting, :live_slot) do
    if MeetingState.slot_void?(meeting), do: {:discard, @slot_void}, else: :ok
  end

  defp check_meeting(%{status: "cancelled"}, :cancelled), do: :ok
  defp check_meeting(_meeting, :cancelled), do: {:discard, @meeting_not_cancelled}
  defp check_meeting(_meeting, _rule), do: :ok

  # A primary-key fetch: every seat job resolves exactly one participant. The
  # meeting-id check guards against a job whose participant belongs to a
  # different meeting ever being treated as this meeting's seat.
  defp fetch_participant(%{id: meeting_id}, participant_id, rule) do
    case ParticipantQueries.get(participant_id) do
      {:ok, %ParticipantSchema{meeting_id: ^meeting_id} = participant} ->
        check_participant(participant, rule)

      _missing_or_foreign ->
        {:discard, @participant_gone}
    end
  end

  defp check_participant(%{cancelled_at: nil} = participant, :live), do: {:ok, participant}
  defp check_participant(_participant, :live), do: {:discard, @participant_gone}

  defp check_participant(%{cancelled_at: nil}, :cancelled),
    do: {:discard, @participant_not_cancelled}

  defp check_participant(participant, :cancelled), do: {:ok, participant}
  defp check_participant(participant, :any), do: {:ok, participant}
end
