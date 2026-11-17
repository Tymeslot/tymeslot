defmodule Tymeslot.MeetingPayments.Workers.GroupCancelRefund do
  @moduledoc """
  Refunds `amount_cents` of one paid seat of a group session on behalf of
  its host, after the host cancelled the whole session
  (`Tymeslot.Meetings.Cancellation`).

  The cancellation inserts one job per paid seat in its own transaction,
  after the session's row is cancelled, so every seat paid by the time the
  cancellation committed is refunded and the Stripe calls never run under
  the session's lock. Each attempt is
  `Tymeslot.MeetingPayments.HostRefundAttempt`, which holds the refund rule,
  the retries, and when the host is emailed.

  When it gives up, the host is emailed
  (`Tymeslot.Workers.SendSeriesRefundFailed`, worded for a cancelled group
  session) to refund the attendee from Stripe.
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
    claim: "group_cancel_refund",
    key_prefix: "group_cancel_refund",
    log_message: "Group session seat refund failed",
    email: [context: :group_meeting]
  ]

  @doc """
  Builds the job refunding `amount_cents` of the seat payment `payment` for
  `host_user_id`. Insert it in the transaction that cancels the session.
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
