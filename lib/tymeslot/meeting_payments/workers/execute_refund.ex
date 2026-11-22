defmodule Tymeslot.MeetingPayments.Workers.ExecuteRefund do
  @moduledoc """
  Finishes a recorded refund (`RefundSchema`) that no caller finished.

  `Refunds.request_refund/4` inserts this job in the transaction that records
  the refund, scheduled a little later as a safety net: a caller that goes on
  to make the refund itself (`Refunds.refund_now/4`) normally settles it
  first, and the job then finds it settled and does nothing. A caller whose
  attempt left the refund pending reschedules the job to run at once
  (`reschedule/2`).

  Each run is one attempt (`Refunds.execute/2`). A refund still pending is
  retried over about four hours (`backoff/1`); each attempt after the first
  first adopts a refund Stripe already made for it. When the last attempt
  leaves it pending, the refund is failed with `"retries_exhausted"` and
  reported (`Refunds.FailureNotice`), unless another attempt holds its lease:
  the job then snoozes until the lease has ended and looks again. A refund
  Stripe refused, or whose charge could not be found, cancels the job: it has
  been failed and reported already.

  At most one job waits per refund.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 10,
    unique: [keys: [:refund_id], states: :incomplete, period: :infinity]

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.MeetingPayments.RefundExecutor
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Workers.Backoff

  # Sixty seconds, doubling, capped at an hour: nine waits between ten
  # attempts add up to 14_580 seconds (4h03m).
  @base_backoff_seconds 60
  @max_backoff_seconds 3_600

  # Long enough for the lease of an attempt in flight to end.
  @lease_wait_seconds 60

  # A job attempt may take this long at Stripe; nobody is waiting on it.
  @deadline_ms 20_000

  # Each of these has been reported already (`Refunds.FailureNotice`), or the
  # refund is gone.
  @expected [:refund_failed, :missing_charge, :retries_exhausted, :not_found]

  @behaviour ExpectedJobOutcome

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason in @expected

  @doc """
  Makes the job of `refund_id` run `in:` seconds from now, in place of when
  it was scheduled. Inserts the job if none waits.
  """
  @spec reschedule(Ecto.UUID.t(), in: non_neg_integer()) :: :ok | {:error, term()}
  def reschedule(refund_id, in: seconds) when is_integer(seconds) and seconds >= 0 do
    job =
      new(%{refund_id: refund_id},
        schedule_in: seconds,
        replace: [scheduled: [:scheduled_at], retryable: [:scheduled_at]]
      )

    case Oban.insert(job) do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refund_id" => id}} = job) do
    case RefundQueries.get(id) do
      nil -> {:discard, :not_found}
      refund -> refund |> attempt(job) |> result(job)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  defp attempt(refund, job),
    do:
      Refunds.execute(refund, from_job: true, deadline_ms: @deadline_ms, last_attempt: last?(job))

  defp result({:ok, _refund}, _job), do: :ok
  defp result({:error, reason}, _job) when reason in @expected, do: {:cancel, reason}

  defp result({:pending, %RefundSchema{} = refund}, job) do
    if last?(job) do
      case RefundExecutor.give_up(refund, "retries_exhausted") do
        {:error, :refund_failed} -> {:cancel, :retries_exhausted}
        {:ok, _settled} -> :ok
        {:pending, _held} -> {:snooze, @lease_wait_seconds}
        {:error, reason} -> {:cancel, reason}
      end
    else
      {:error, :pending}
    end
  end

  defp last?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
end
