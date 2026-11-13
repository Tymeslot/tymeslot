defmodule Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker do
  @moduledoc """
  Releases one unverified booking at its verification deadline.

  Scheduled at `verification_deadline_at` when the booking is made, so the
  slot frees the moment the hold ends. `EmailVerificationSweepWorker` is the
  backstop for a job that never runs; the two overlap safely because
  `EmailVerification.expire/1` is a guarded transition, so the second to
  arrive finds nothing held and does nothing.

  `max_attempts: 1`, as for `ApprovalExpiryWorker`: a retry minutes later
  would find the booking already released or verified, and the sweep covers
  a genuinely failed attempt.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 315_360_000, fields: [:args, :worker], keys: [:meeting_id]]

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState

  @behaviour ExpectedJobOutcome

  # The meeting was deleted, or the attendee verified (or the booking was
  # released) before the job ran: a stale job with nothing to do. A booking
  # not yet due is unexpected, since the deadline never moves, so it is
  # recorded. Each reason keeps its variable detail after `": "`, so every
  # meeting shares one error group.
  @meeting_gone "Meeting not found"
  @no_longer_held "Booking no longer awaiting verification"
  @released_while_expiring "Booking left verification while expiring"
  @not_due "Verification not due yet"

  @impl ExpectedJobOutcome
  def expected_outcome?(@released_while_expiring), do: true

  def expected_outcome?(reason) when is_binary(reason),
    do: String.starts_with?(reason, [@meeting_gone <> ": ", @no_longer_held <> ": "])

  def expected_outcome?(_reason), do: false

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id}}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> expire_if_held(meeting)
      {:error, :not_found} -> {:discard, "#{@meeting_gone}: #{meeting_id}"}
    end
  end

  defp expire_if_held(meeting) do
    cond do
      not MeetingState.awaiting_verification?(meeting) ->
        {:discard, "#{@no_longer_held}: #{meeting.status}"}

      deadline_in_future?(meeting) ->
        {:discard, "#{@not_due}: #{meeting.verification_deadline_at}"}

      true ->
        release(meeting)
    end
  end

  defp deadline_in_future?(%{verification_deadline_at: nil}), do: false

  defp deadline_in_future?(%{verification_deadline_at: deadline}),
    do: DateTime.compare(deadline, Clock.utc_now()) == :gt

  defp release(meeting) do
    case EmailVerification.expire(meeting) do
      {:ok, _expired} -> :ok
      {:error, :not_awaiting_verification} -> {:discard, @released_while_expiring}
    end
  rescue
    # With one attempt, an unrescued raise is discarded with no domain log
    # line; surface the meeting here, as `ApprovalExpiryWorker` does.
    exception ->
      Logger.error("Email verification expiry could not release a booking",
        meeting_id: meeting.id,
        error: LogFormat.reason(exception),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )

      {:error, exception}
  end
end
