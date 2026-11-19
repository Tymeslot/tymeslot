defmodule Tymeslot.Workers.SendSeriesRefundFailed do
  @moduledoc """
  Tells the host that the refund of a series payment, scheduled when they
  cancelled the series' remaining sessions, could not be made
  (`Tymeslot.Emails.Templates.SeriesRefundFailed`).

  Enqueued by `Tymeslot.MeetingPayments.Workers.SeriesHostRefund` when it
  gives up on a refund: discarded as one no retry can make, or out of
  attempts. Loads a fresh booking-payment row inside `perform/1`, and sends
  nothing once the payment is gone. The send is claimed through
  `Tymeslot.Workers.DeliveryClaims`, so a rescued job does not send it twice.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    priority: 0,
    unique: [
      keys: [:booking_payment_id, :amount_cents, :refunded_before_cents],
      states: :all,
      period: :infinity
    ]

  require Logger

  alias Tymeslot.Emails.Templates.SeriesRefundFailed
  alias Tymeslot.Emails.Templates.SeriesRefundFailed.RefundContext
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @behaviour ExpectedJobOutcome

  @payment_gone "booking_payment not found"

  # The refusals the email can explain, by their name in the job args; any
  # other reason reads as a refund Stripe kept refusing.
  @reasons %{"outside_refund_window" => :outside_refund_window, "under_dispute" => :under_dispute}

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do: reason == @payment_gone or TransactionalEmailDelivery.recipient_rejected?(reason)

  @doc """
  The job telling the host of `payment` that refunding `amount_cents` of it
  failed, for `reason` (an atom, or anything else for a failure no retry
  got past). `refunded_before_cents` names the refund attempt, as
  `SeriesHostRefund` does, so one failed refund sends one email.
  """
  @spec new_for(binary(), pos_integer(), non_neg_integer(), term()) :: Oban.Job.changeset()
  def new_for(booking_payment_id, amount_cents, refunded_before_cents, reason) do
    new(%{
      booking_payment_id: booking_payment_id,
      amount_cents: amount_cents,
      refunded_before_cents: refunded_before_cents,
      reason: reason_arg(reason)
    })
  end

  defp reason_arg(reason) when reason in [:outside_refund_window, :under_dispute],
    do: Atom.to_string(reason)

  defp reason_arg(_reason), do: nil

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => id} = args} = job) do
    case MeetingPayments.get_payment(id) do
      nil ->
        {:discard, @payment_gone}

      %BookingPaymentSchema{host_email: host_email} when host_email in [nil, ""] ->
        Logger.warning("Series refund failure email skipped — no host email",
          booking_payment_id: id
        )

        {:discard, "missing host_email"}

      %BookingPaymentSchema{} = payment ->
        DeliveryClaims.once(job, "series_refund_failed_email", fn ->
          payment
          |> context(args)
          |> SeriesRefundFailed.render()
          |> TransactionalEmailDelivery.deliver(job, "Series refund failure email failed",
            booking_payment_id: payment.id
          )
        end)
    end
  end

  defp context(payment, args) do
    # A series payment is named after its first session.
    meeting = payment |> MeetingPayments.meetings_for_payment() |> List.first()

    %RefundContext{
      host_email: payment.host_email,
      host_name: payment.host_name,
      host_user_id: payment.host_user_id,
      amount_cents: args["amount_cents"],
      currency: payment.currency,
      attendee_name: payment.attendee_name,
      attendee_email: payment.attendee_email,
      meeting_title: meeting_title(meeting, payment),
      reason: Map.get(@reasons, args["reason"])
    }
  end

  defp meeting_title(%{title: title}, _payment) when is_binary(title) and title != "", do: title
  defp meeting_title(_meeting, %{meeting_type_name: name}) when is_binary(name), do: name
  defp meeting_title(_meeting, _payment), do: nil
end
