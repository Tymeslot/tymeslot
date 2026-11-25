defmodule Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker do
  @moduledoc """
  Releases one unverified booking (`"meeting_id"`), or one unverified seat on
  a group meeting (`"participant_id"`), at its verification deadline.

  Scheduled at `verification_deadline_at` when the booking is made, so the
  slot frees the moment the hold ends. `EmailVerificationSweepWorker` is the
  backstop for a job that never runs; the two overlap safely because
  `EmailVerification.expire/1` and `expire_seat/1` are guarded transitions, so the second to
  arrive finds nothing held and does nothing.

  `max_attempts: 1`, as for `ApprovalExpiryWorker`: a retry minutes later
  would find the booking already released or verified, and the sweep covers
  a genuinely failed attempt.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      period: 315_360_000,
      fields: [:args, :worker],
      keys: [:meeting_id, :participant_id]
    ]

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant

  @behaviour ExpectedJobOutcome

  # The meeting or seat was deleted, or the attendee verified (or the booking was
  # released) before the job ran: a stale job with nothing to do. A booking
  # not yet due is unexpected, since the deadline never moves, so it is
  # recorded. Each reason keeps its variable detail after `": "`, so every
  # meeting shares one error group.
  @meeting_gone "Meeting not found"
  @seat_gone "Seat not found"
  @no_longer_held "Booking no longer awaiting verification"
  @released_while_expiring "Booking left verification while expiring"
  @not_due "Verification not due yet"

  @impl ExpectedJobOutcome
  def expected_outcome?(@released_while_expiring), do: true

  def expected_outcome?(reason) when is_binary(reason),
    do:
      String.starts_with?(reason, [
        @meeting_gone <> ": ",
        @seat_gone <> ": ",
        @no_longer_held <> ": "
      ])

  def expected_outcome?(_reason), do: false

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id}}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> expire_if_held(meeting)
      {:error, :not_found} -> {:discard, "#{@meeting_gone}: #{meeting_id}"}
    end
  end

  def perform(%Oban.Job{args: %{"participant_id" => participant_id}}) do
    case ParticipantQueries.get(participant_id) do
      {:ok, seat} -> expire_seat_if_held(seat)
      {:error, :not_found} -> {:discard, "#{@seat_gone}: #{participant_id}"}
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

  defp expire_seat_if_held(seat) do
    cond do
      not Participant.live?(seat) -> {:discard, "#{@no_longer_held}: cancelled"}
      not Participant.unverified?(seat) -> {:discard, "#{@no_longer_held}: verified"}
      deadline_in_future?(seat) -> {:discard, "#{@not_due}: #{seat.verification_deadline_at}"}
      true -> release_seat(seat)
    end
  end

  defp deadline_in_future?(%{verification_deadline_at: nil}), do: false

  defp deadline_in_future?(%{verification_deadline_at: deadline}),
    do: DateTime.compare(deadline, Clock.utc_now()) == :gt

  defp release(meeting),
    do: guarded(fn -> EmailVerification.expire(meeting) end, meeting_id: meeting.id)

  defp release_seat(seat),
    do: guarded(fn -> EmailVerification.expire_seat(seat) end, participant_id: seat.id)

  defp guarded(expire, log_metadata) do
    case expire.() do
      {:ok, _expired} -> :ok
      {:error, :not_awaiting_verification} -> {:discard, @released_while_expiring}
    end
  rescue
    # With one attempt, an unrescued raise is discarded with no domain log
    # line; surface the booking or seat here, as `ApprovalExpiryWorker` does.
    exception ->
      Logger.error(
        "Email verification expiry could not release a booking",
        log_metadata ++
          [
            error: LogFormat.reason(exception),
            stacktrace: LogFormat.stacktrace(__STACKTRACE__)
          ]
      )

      {:error, exception}
  end
end
