defmodule Tymeslot.Meetings.Workers.EmailVerificationSweepWorker do
  @moduledoc """
  Cron backstop that releases unverified bookings whose deadline has passed.

  `EmailVerificationExpiryWorker` handles the punctual case; this catches the
  bookings whose job was lost. It runs every 5 minutes rather than every 15
  like `ApprovalSweepWorker`, because a hold lasts only 30 minutes and a
  quarter-hour lag would be half of it again.

  One failing booking does not stop the sweep: it is reported and counted,
  and the rest are still processed. `@batch_limit` bounds a run; a larger
  backlog is worked through over successive runs, oldest deadline first.
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

  @batch_limit 200

  @type sweep_result :: %{
          expired: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(_job) do
    result =
      Clock.utc_now()
      |> MeetingQueries.list_expired_verifications(@batch_limit)
      |> Enum.reduce(%{expired: 0, skipped: 0, failed: 0}, &tally(expire_one(&1), &2))

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
