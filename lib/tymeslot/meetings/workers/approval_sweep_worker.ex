defmodule Tymeslot.Meetings.Workers.ApprovalSweepWorker do
  @moduledoc """
  Cron backstop that releases held bookings whose deadline has passed.

  `ApprovalExpiryWorker` handles the punctual case; this exists for the
  requests it never got to. Runs every 15 minutes, so the worst case for a
  request whose scheduled job was lost is a quarter-hour of extra hold rather
  than an indefinite one.

  One host's failure must not stop the sweep: a request that cannot be
  released is logged and counted, and the remaining requests are still
  processed. Each release is independently guarded, so a request answered
  mid-sweep is skipped rather than overwritten.

  `@batch_limit` bounds a single run. A backlog larger than the limit is
  worked through over successive runs, oldest deadline first, rather than
  loading an unbounded result set and holding the queue for it.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 60]

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries

  @batch_limit 200

  @type sweep_result :: %{expired: non_neg_integer(), skipped: non_neg_integer()}

  @impl Oban.Worker
  def perform(_job) do
    result =
      Clock.utc_now()
      |> MeetingQueries.list_expired_approval_requests(@batch_limit)
      |> Enum.reduce(%{expired: 0, skipped: 0}, &tally(expire_one(&1), &2))

    log(result)

    {:ok, result}
  end

  defp expire_one(meeting) do
    case Approval.expire(meeting) do
      {:ok, _expired} ->
        :expired

      # The host answered between the query and the update. Correct outcome,
      # not a failure.
      {:error, :not_awaiting_approval} ->
        :skipped
    end
  rescue
    exception ->
      Logger.error("Approval sweep could not release a request",
        meeting_id: meeting.id,
        error: Exception.format(:error, exception, __STACKTRACE__)
      )

      :skipped
  end

  defp tally(outcome, acc), do: Map.update!(acc, outcome, &(&1 + 1))

  # Silence when there is nothing to do: this runs 96 times a day on an
  # instance where most hosts require no approval at all.
  defp log(%{expired: 0, skipped: 0}), do: :ok

  defp log(result) do
    Logger.info("Approval sweep complete",
      expired: result.expired,
      skipped: result.skipped
    )
  end
end
