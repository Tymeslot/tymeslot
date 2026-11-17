defmodule Tymeslot.MeetingPayments.Workers.SeriesHostRefund do
  @moduledoc """
  Refunds `amount_cents` of a series payment on behalf of its host, after
  the host cancelled the sessions of the series still to come
  (`Tymeslot.BookingSeries.Cancel`).

  The cancellation inserts this job in its own transaction, so the refund is
  recorded with the sessions it pays back for, or not at all, and the Stripe
  call never runs inside that transaction. Each attempt is
  `Tymeslot.MeetingPayments.HostRefundAttempt`, which holds the refund rule,
  the retries, and when the host is emailed. Other refunds of the same
  payment (the host refunding one session as they cancel it) can land
  between the cancellation and the job; the attempt's claim, not the
  payment's running total, says whether this job's refund was made.

  When it gives up, the host is emailed
  (`Tymeslot.Workers.SendSeriesRefundFailed`): the series payment appears
  on their outstanding-refunds list only once none of its sessions goes
  ahead, so the email is how they learn the money is still theirs to
  return.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 10,
    unique: [
      keys: [:booking_payment_id, :refunded_before_cents, :amount_cents],
      states: :all,
      period: :infinity
    ]

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.HostRefundAttempt

  @attempt [
    claim: "series_host_refund",
    key_prefix: "series_refund",
    log_message: "Series host refund failed"
  ]

  @doc """
  Builds the job refunding `amount_cents` of `payment` for `host_user_id`.
  Insert it in the transaction that cancels the sessions it pays back for.
  """
  @spec new_for(BookingPaymentSchema.t(), integer(), pos_integer()) :: Oban.Job.changeset()
  def new_for(%BookingPaymentSchema{} = payment, host_user_id, amount_cents)
      when is_integer(host_user_id) and is_integer(amount_cents) and amount_cents > 0 do
    new(%{
      booking_payment_id: payment.id,
      host_user_id: host_user_id,
      amount_cents: amount_cents,
      refunded_before_cents: payment.refunded_amount_cents
    })
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: HostRefundAttempt.perform(job, @attempt)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: HostRefundAttempt.backoff(attempt)
end
