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
  first adopts a refund Stripe already made for it. An attempt after one
  whose request Stripe answered with an error that leaves the refund open
  waits first, snoozing until Stripe has had time to list a refund that
  request may have made (`RefundExecutor.settle_wait_seconds/1`); the
  snooze spends none of the job's attempts. The last attempt sends
  no new request: it adopts the refund if Stripe made it, and otherwise
  fails it with `"retries_exhausted"` and reports it
  (`Refunds.FailureNotice`). A refund Stripe refused, or whose charge could
  not be found, cancels the job: it has been failed and reported already.
  A last attempt that leaves the refund pending because Stripe's refunds
  could not be read for now raises a `:refund_stuck` alert; one that met
  another attempt's lease leaves the outcome to that attempt. Either way,
  as for a last attempt that raised, the job ends as failed and
  `SweepPendingRefunds` gives the refund a new job. A read Stripe refuses
  for good (a revoked Connect account) leaves the refund pending too,
  since an earlier request may have made it: it is reported as stuck at
  once, and the job snoozes and tries again, in case the account is
  reconnected, first after fifteen minutes and twice as long each
  time after, up to a day apart, until the refund is settled (by
  `Tymeslot.Release.settle_stuck_refund/2`, say). The waiting job keeps the
  sweeper from giving the refund another.

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
  alias Tymeslot.MeetingPayments.Refunds.FailureNotice
  alias Tymeslot.Workers.Backoff

  # Sixty seconds, doubling, capped at an hour: nine waits between ten
  # attempts add up to 14_580 seconds (4h03m).
  @base_backoff_seconds 60
  @max_backoff_seconds 3_600

  # A refund whose charge's refunds Stripe will not list is tried again
  # after fifteen minutes, doubling each time the job has waited, up to a
  # day: an operator settles it, or the account is reconnected, within days,
  # not minutes, and each try costs a Stripe call and an error log.
  @stuck_base_seconds 15 * 60
  @stuck_max_seconds 24 * 60 * 60

  # A job attempt may take this long at Stripe; nobody is waiting on it.
  @deadline_ms 20_000

  # Each of these has been reported already (`Refunds.FailureNotice`), or the
  # refund is gone.
  @expected [:refund_failed, :missing_charge, :not_found]

  # An attempt that left the refund pending (a Stripe timeout, a lease held
  # by another attempt) is retried, and is a wait rather than a failure; a
  # last attempt that leaves it pending reports it as stuck itself.
  @pending :pending

  @behaviour ExpectedJobOutcome

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason in [@pending | @expected]

  @impl ExpectedJobOutcome
  def expected_retry?(reason), do: reason == @pending

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
      refund -> run(refund, job)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  defp run(refund, job) do
    case RefundExecutor.settle_wait_seconds(refund) do
      0 -> refund |> attempt(job) |> result(job)
      seconds -> {:snooze, seconds}
    end
  end

  defp attempt(refund, job),
    do:
      Refunds.execute(refund, from_job: true, deadline_ms: @deadline_ms, last_attempt: last?(job))

  defp result({:ok, _refund}, _job), do: :ok
  defp result({:error, reason}, _job) when reason in @expected, do: {:cancel, reason}

  defp result({:stuck, _refund}, %Oban.Job{meta: meta}) do
    waited = Map.get(meta, "snoozed", 0)
    {:snooze, Backoff.exponential(waited + 1, @stuck_base_seconds, @stuck_max_seconds)}
  end

  defp result({:pending, refund}, job) do
    if last?(job) and not RefundQueries.leased?(refund), do: FailureNotice.stuck(refund)
    {:error, @pending}
  end

  defp last?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
end
