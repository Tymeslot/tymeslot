defmodule Tymeslot.MeetingPayments.RefundedTotal do
  @moduledoc """
  How much of a booking payment the attendee has been given back, and by
  which route.

  Three figures, kept in step by the `with_*` functions, which return all
  three with the status that follows, so a caller writes them together:

    * `stripe_refunded_cents`, the refunds made at Stripe, as the charge's
      `amount_refunded` reports them;
    * `disputed_lost_cents`, what a lost dispute took back;
    * `refunded_amount_cents`, the whole of it, the figure every balance,
      status and list reads: the two parts added, never more than the
      amount paid.

  The parts are kept apart because Stripe's `amount_refunded` counts
  refunds only: compared with the whole, a refund made after a partly lost
  dispute would look already recorded (and never be), and an amount the
  dispute took would look like a refund Stripe may already have made.

  The whole stops at the amount paid. An attendee refunded first and then
  paid back again by a dispute the host lost over the same money has been
  repaid twice, and is owed nothing more; the refunds keep their own
  figure, so that payment still shows (and tells the attendee of) the
  refund made.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentSchema

  @type figures :: %{
          stripe_refunded_cents: non_neg_integer(),
          disputed_lost_cents: non_neg_integer(),
          refunded_amount_cents: non_neg_integer(),
          status: BookingPaymentSchema.status()
        }

  @doc """
  The refunds made at Stripe, without what a lost dispute took.
  """
  @spec stripe_refunded_cents(BookingPaymentSchema.t()) :: non_neg_integer()
  def stripe_refunded_cents(%{stripe_refunded_cents: refunds}) when is_integer(refunds),
    do: refunds

  @doc """
  What may still be refunded while refunds of `pending_cents` are in
  flight. The whole already counts a lost dispute's part, so it is not
  taken off again.
  """
  @spec refundable_cents(BookingPaymentSchema.t(), non_neg_integer()) :: non_neg_integer()
  def refundable_cents(%{amount_cents: amount, refunded_amount_cents: refunded}, pending_cents)
      when is_integer(amount) and is_integer(refunded) and is_integer(pending_cents),
      do: max(amount - refunded - pending_cents, 0)

  @doc """
  The figures once Stripe reports `stripe_total` refunded on the charge.
  Never below the refunds already recorded, so a late or replayed report
  cannot undo one.
  """
  @spec with_stripe_refunded(BookingPaymentSchema.t(), non_neg_integer()) :: figures()
  def with_stripe_refunded(payment, stripe_total) when is_integer(stripe_total),
    do:
      figures(
        payment,
        max(payment.stripe_refunded_cents, stripe_total),
        payment.disputed_lost_cents
      )

  @doc """
  The figures once one refund of `amount_cents` is recorded as made, Stripe
  reporting `stripe_total` refunded on its charge: the refunds raised by
  the amount, but not past Stripe's total, and never lowered.

  Stripe's total alone would do but for one case: a total read before a
  refund failed, whose failure was taken off since (`with_refund_failed/2`),
  still counts that refund, and raising the refunds to it would count it
  again for good. The amount bounds the rise, and the total stops a refund
  already counted (by a `charge.refunded` total that holds it) from being
  counted twice. A total holding refunds not recorded yet is reached by
  their own reports.
  """
  @spec with_refund_made(BookingPaymentSchema.t(), non_neg_integer(), non_neg_integer()) ::
          figures()
  def with_refund_made(%{stripe_refunded_cents: refunds} = payment, stripe_total, amount_cents)
      when is_integer(stripe_total) and is_integer(amount_cents),
      do:
        figures(
          payment,
          max(refunds, min(stripe_total, refunds + amount_cents)),
          payment.disputed_lost_cents
        )

  @doc """
  The figures once a recorded refund of `amount_cents` is reported failed
  at Stripe, which gives the money back to the host. The only report of
  Stripe's that lowers the refunds; the dispute's part is kept.
  """
  @spec with_refund_failed(BookingPaymentSchema.t(), pos_integer()) :: figures()
  def with_refund_failed(payment, amount_cents) when is_integer(amount_cents),
    do:
      figures(
        payment,
        payment.stripe_refunded_cents - amount_cents,
        payment.disputed_lost_cents
      )

  @doc """
  The status a payment takes once its whole is `total`. A disputed payment
  stays disputed: the dispute owns the status, and the total only tracks
  the money.
  """
  @spec status_for(BookingPaymentSchema.t(), non_neg_integer()) :: BookingPaymentSchema.status()
  def status_for(%{status: :disputed}, _total), do: :disputed

  def status_for(%{amount_cents: amount}, total) when is_integer(total) do
    cond do
      total >= amount -> :refunded
      total > 0 -> :partially_refunded
      true -> :paid
    end
  end

  @doc """
  The figures recording a lost dispute over `disputed_cents`, the refunds
  made kept as they are. A charge is disputed once, so a second report of
  the loss (another event for the same dispute) records it once. The
  status is `status_for/2`'s, which leaves a payment still `disputed`; the
  dispute's close decides the status itself.
  """
  @spec with_dispute_lost(BookingPaymentSchema.t(), non_neg_integer()) :: figures()
  def with_dispute_lost(payment, disputed_cents) when is_integer(disputed_cents),
    do:
      figures(
        payment,
        payment.stripe_refunded_cents,
        max(disputed_cents, payment.disputed_lost_cents)
      )

  @doc """
  The figures of `payment` with refunds made of `refunds` and a lost
  dispute's part of `lost`, each held within the amount paid, and the
  status their whole implies (`status_for/2`).
  """
  @spec figures(BookingPaymentSchema.t(), integer(), integer()) :: figures()
  def figures(%{amount_cents: amount} = payment, refunds, lost)
      when is_integer(amount) and is_integer(refunds) and is_integer(lost) do
    refunds = refunds |> max(0) |> min(amount)
    lost = lost |> max(0) |> min(amount)
    whole = min(refunds + lost, amount)

    %{
      stripe_refunded_cents: refunds,
      disputed_lost_cents: lost,
      refunded_amount_cents: whole,
      status: status_for(payment, whole)
    }
  end
end
