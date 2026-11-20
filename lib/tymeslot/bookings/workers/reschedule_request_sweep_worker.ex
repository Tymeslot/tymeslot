defmodule Tymeslot.Bookings.Workers.RescheduleRequestSweepWorker do
  @moduledoc """
  Cron backstop that expires host reschedule requests whose deadline has
  passed unanswered (`Tymeslot.Bookings.RescheduleRequestExpiry`).

  `RescheduleRequestExpiryWorker` handles the punctual case; this covers a
  request whose job was lost, and every request already open when expiry
  was introduced, which has no job at all. Runs every 15 minutes, so a
  request is expired at most a quarter-hour late; the booking rules refuse an
  answer from the deadline itself, whatever this has done.

  One failure does not stop the sweep: it is reported and counted, and the
  remaining requests are still processed. `@batch_limit` bounds one run; a
  larger backlog is worked through over successive runs, oldest request
  first.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 60]

  require Logger

  alias Tymeslot.Bookings.RescheduleRequestExpiry
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Meetings.MeetingQueries

  @batch_limit 200

  @impl Oban.Worker
  def perform(_job) do
    result =
      Clock.utc_now()
      |> MeetingQueries.list_lapsed_reschedule_requests(@batch_limit)
      |> Enum.reduce(%{expired: 0, skipped: 0, failed: 0}, &tally(expire_one(&1), &2))

    log(result)

    {:ok, result}
  end

  defp expire_one(meeting) do
    case RescheduleRequestExpiry.expire(meeting) do
      {:ok, _expired} -> :expired
      # The attendee answered between the query and the update.
      {:error, :not_lapsed} -> :skipped
      {:error, _reason} -> :failed
    end
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{meeting_id: meeting.id})
      :failed
  end

  defp tally(outcome, acc), do: Map.update!(acc, outcome, &(&1 + 1))

  defp log(%{expired: 0, skipped: 0, failed: 0}), do: :ok

  defp log(result) do
    Logger.info("Reschedule request sweep complete",
      expired: result.expired,
      skipped: result.skipped,
      failed: result.failed
    )
  end
end
