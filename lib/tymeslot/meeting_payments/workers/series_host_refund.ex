defmodule Tymeslot.MeetingPayments.Workers.SeriesHostRefund do
  @moduledoc """
  Runs jobs queued before 1.49; delete after that release.

  Such a job refunds `amount_cents` of a series payment for its host, after
  the host cancelled the series' remaining sessions
  (`Tymeslot.BookingSeries.Cancel`, which now records the refund itself).

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
  nothing. A refund no retry can make (outside the refund window, under
  dispute, not paid, more than remains) discards the job.
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

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Repo
  alias Tymeslot.Workers.Backoff
  alias Tymeslot.Workers.DeliveryClaims

  @claim "series_host_refund"

  @base_backoff_seconds 60
  @max_backoff_seconds 3_600

  @unretryable [
    :not_found,
    :not_paid,
    :outside_refund_window,
    :under_dispute,
    :already_refunded,
    :invalid_amount,
    :refund_in_progress
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case request(job, args) do
      {:ok, _requested} ->
        :ok

      {:error, reason} when reason in @unretryable ->
        Logger.error("Series host refund cannot be made",
          booking_payment_id: args["booking_payment_id"],
          amount_cents: args["amount_cents"],
          reason: reason
        )

        {:discard, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  defp request(job, %{
         "booking_payment_id" => id,
         "host_user_id" => host_user_id,
         "amount_cents" => amount
       }) do
    with %BookingPaymentSchema{} = payment <- MeetingPayments.get_payment(id),
         false <- DeliveryClaims.claimed?(job.id, @claim) do
      request_once(job, payment, host_user_id, amount)
    else
      nil -> {:error, :not_found}
      true -> {:ok, :requested}
    end
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
end
