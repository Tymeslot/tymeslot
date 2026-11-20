defmodule Tymeslot.MeetingPayments.RefundedTotal do
  @moduledoc """
  How much of a booking payment the attendee has been given back, and by
  which route.

  `refunded_amount_cents` is the whole of it, the figure every balance,
  status and list reads: refunds made at Stripe plus what a lost dispute
  took back. `disputed_lost_cents` is the dispute's part. The two are kept
  apart because Stripe's `amount_refunded` on a charge counts refunds only:
  compared with the whole, a refund made after a partly lost dispute would
  look already recorded (and never be), and an amount the dispute took
  would look like a refund Stripe may already have made.

  The whole never exceeds the amount paid. An attendee refunded first and
  then paid back again by a dispute the host lost over the same money has
  been repaid twice, and is owed nothing more.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentSchema

  @doc "The refunds made at Stripe, without what a lost dispute took."
  @spec stripe_refunded_cents(BookingPaymentSchema.t()) :: non_neg_integer()
  def stripe_refunded_cents(%{refunded_amount_cents: refunded, disputed_lost_cents: lost})
      when is_integer(refunded) and is_integer(lost),
      do: max(refunded - lost, 0)

  @doc """
  The whole once Stripe reports `stripe_total` refunded on the charge.
  Never below the refunds already recorded, so a late or replayed report
  cannot undo one.
  """
  @spec with_stripe_refunded(BookingPaymentSchema.t(), non_neg_integer()) :: non_neg_integer()
  def with_stripe_refunded(payment, stripe_total) when is_integer(stripe_total),
    do:
      whole(
        payment,
        max(stripe_refunded_cents(payment), stripe_total),
        payment.disputed_lost_cents
      )

  @doc "The whole once a refund of `amount_cents` is added to the recorded refunds."
  @spec with_refund_added(BookingPaymentSchema.t(), pos_integer()) :: non_neg_integer()
  def with_refund_added(payment, amount_cents) when is_integer(amount_cents),
    do: whole(payment, stripe_refunded_cents(payment) + amount_cents, payment.disputed_lost_cents)

  @doc """
  The attributes recording a lost dispute over `disputed_cents`. A charge
  is disputed once, so a second report of the loss (another event for the
  same dispute) records it once.
  """
  @spec with_dispute_lost(BookingPaymentSchema.t(), non_neg_integer()) :: %{
          refunded_amount_cents: non_neg_integer(),
          disputed_lost_cents: non_neg_integer()
        }
  def with_dispute_lost(payment, disputed_cents) when is_integer(disputed_cents) do
    lost = disputed_cents |> max(payment.disputed_lost_cents) |> min(payment.amount_cents)

    %{
      refunded_amount_cents: whole(payment, stripe_refunded_cents(payment), lost),
      disputed_lost_cents: lost
    }
  end

  defp whole(%{amount_cents: amount}, refunds, lost)
       when is_integer(amount) and is_integer(refunds) and is_integer(lost),
       do: min(refunds + lost, amount)
end
