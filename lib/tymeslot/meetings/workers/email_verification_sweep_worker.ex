defmodule Tymeslot.Meetings.Workers.EmailVerificationSweepWorker do
  @moduledoc """
  Cron backstop that releases unverified bookings, and unverified seats on
  group meetings, whose deadline has passed. A held group slot is never
  expired here by its own deadline; it is voided when its last held seat
  expires (`EmailVerification.expire_seat/1`).

  `EmailVerificationExpiryWorker` handles the punctual case; this catches the
  bookings whose job was lost. It runs every 5 minutes rather than every 15
  like `ApprovalSweepWorker`, because a hold lasts only 30 minutes and a
  quarter-hour lag would be half of it again.

  One failing booking does not stop the sweep: it is reported and counted,
  and the rest are still processed. `@batch_limit` bounds each kind per run
  (bookings, then seats); a larger backlog is worked through over successive
  runs, oldest deadline first.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 60]

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries

  @batch_limit 200

  @type sweep_result :: %{
          expired: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(_job) do
    now = Clock.utc_now()
    tallied = %{expired: 0, skipped: 0, failed: 0}

    tallied =
      now
      |> MeetingQueries.list_expired_verifications(@batch_limit)
      |> Enum.reduce(tallied, &tally(expire_one(&1), &2))

    result =
      now
      |> ParticipantQueries.list_expired_verifications(@batch_limit)
      |> Enum.reduce(tallied, &tally(expire_seat(&1), &2))

    log(result)

    {:ok, result}
  end

  defp expire_one(meeting) do
    case EmailVerification.expire(meeting) do
      {:ok, _expired} -> :expired
      # Verified or released between the query and the update: correct.
      {:error, :not_awaiting_verification} -> :skipped
    end
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{meeting_id: meeting.id})
      :failed
  end

  defp expire_seat(seat) do
    case EmailVerification.expire_seat(seat) do
      {:ok, _expired} -> :expired
      {:error, :not_awaiting_verification} -> :skipped
    end
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{participant_id: seat.id})
      :failed
  end

  defp tally(outcome, acc), do: Map.update!(acc, outcome, &(&1 + 1))

  # Silent when there is nothing to do: this runs 288 times a day.
  defp log(%{expired: 0, skipped: 0, failed: 0}), do: :ok

  defp log(result) do
    Logger.info("Email verification sweep complete",
      expired: result.expired,
      skipped: result.skipped,
      failed: result.failed
    )
  end
end
