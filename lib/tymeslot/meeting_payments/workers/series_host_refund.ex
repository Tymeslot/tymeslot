defmodule Tymeslot.MeetingPayments.Workers.SeriesHostRefund do
  @moduledoc """
  Runs jobs queued before the release that brought in the refund outbox
  (`booking_payment_refunds`); delete in the release after it.

  Such a job refunds `amount_cents` of a series payment for its host, after
  the host cancelled the series' remaining sessions. Nothing inserts such
  jobs: `Tymeslot.BookingSeries.Cancel` records the refund itself.

  A run records the refund (`Refunds.request_refund/4`, source
  `:series_host`, scoped to the host) and leaves it to `ExecuteRefund`,
  which makes it, retries it, and emails the host if it fails for good
  (`Refunds.FailureNotice`). An earlier attempt of the job may have refunded
  at Stripe under its key (`series_refund:<job id>`) without recording it,
  so the refund carries that key and the job's `inserted_at`, from when the
  key could first have been sent: the executor replays the key while Stripe
  keeps it, and adopts a refund it made after that.

  Whether the refund is made already is the job's own record: an earlier
  attempt that recorded it holds the job's delivery claim
  (`DeliveryClaims`), committed with what it recorded, so a rerun records
  nothing.

  A refund no retry can make (outside the refund window, under dispute,
  not paid, more than remains) discards the job. Another refund of the
  payment still pending (`:refund_in_progress`) settles within minutes, so
  that refusal is retried, as is any other failure. When the job gives up
  on the refund, discarded or failed on its last attempt, the host is
  emailed (`Tymeslot.Workers.SendSeriesRefundFailed`): the series payment
  reaches their outstanding-refunds list only once none of its sessions
  goes ahead, so the email is how they learn the money is still theirs to
  return. No email goes out when the payment is gone or already refunded.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 10,
    unique: [
      keys: [:booking_payment_id, :refunded_before_cents, :amount_cents],
      states: :all,
      period: :infinity
    ]

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Repo
  alias Tymeslot.Workers.Backoff
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.SendSeriesRefundFailed

  @claim "series_host_refund"

  @base_backoff_seconds 60
  @max_backoff_seconds 3_600

  # Refusals that leave the host nothing to return: no payment of theirs,
  # or its money refunded already.
  @nothing_owed [:not_found, :already_refunded]

  # Refusals no retry can turn round; the money stays with the host.
  @unretryable [:not_paid, :outside_refund_window, :under_dispute, :invalid_amount]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case request(job, args) do
      {:ok, _requested} ->
        :ok

      {:error, reason} when reason in @nothing_owed ->
        log_failure(job, args, reason)
        {:discard, reason}

      {:error, reason} when reason in @unretryable ->
        log_failure(job, args, reason)
        tell_host(args)
        {:discard, reason}

      {:error, reason} ->
        log_failure(job, args, reason)
        if job.attempt >= job.max_attempts, do: tell_host(args)
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  # A raise (a dropped connection, say) is an attempt failing like any
  # other, so the last one still tells the host.
  defp request(job, %{
         "booking_payment_id" => id,
         "host_user_id" => host_user_id,
         "amount_cents" => amount
       }) do
    with %BookingPaymentSchema{} = payment <- BookingPayments.get_payment(id),
         false <- DeliveryClaims.claimed?(job.id, @claim) do
      request_once(job, payment, host_user_id, amount)
    else
      nil -> {:error, :not_found}
      true -> {:ok, :requested}
    end
  rescue
    exception -> {:error, exception}
  end

  # The claim and the refund commit together; a refusal rolls both back. A
  # job with no id (built by hand) cannot run twice, so claims nothing.
  defp request_once(job, payment, host_user_id, amount) do
    Repo.transaction(fn ->
      with :claimed <- claim(job.id),
           {:ok, refund} <-
             Refunds.request_refund(
               payment,
               amount,
               :series_host,
               [host_user_id: host_user_id, enqueue_now: true] ++ legacy(job)
             ) do
        refund
      else
        :already_claimed -> :requested
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp claim(nil), do: :claimed
  defp claim(job_id), do: DeliveryClaims.claim(job_id, @claim)

  defp legacy(%Oban.Job{id: nil}), do: []

  defp legacy(%Oban.Job{id: id, inserted_at: inserted_at}),
    do: [legacy_idempotency_key: "series_refund:#{id}", legacy_since: inserted_at]

  defp tell_host(%{"booking_payment_id" => id, "amount_cents" => amount}) do
    case Oban.insert(SendSeriesRefundFailed.new(%{booking_payment_id: id, amount_cents: amount})) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not queue the series refund failure email",
          booking_payment_id: id,
          reason: LogFormat.reason(reason)
        )
    end
  end

  defp log_failure(job, args, reason) do
    Logger.error("Series host refund cannot be made",
      booking_payment_id: args["booking_payment_id"],
      amount_cents: args["amount_cents"],
      attempt: job.attempt,
      reason: LogFormat.reason(reason)
    )
  end
end
