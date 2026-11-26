defmodule Tymeslot.Workers.SendRefundFailed do
  @moduledoc """
  Tells the host that a refund they decided (from the payments page, by
  cancelling a booking, or by cancelling a series' remaining sessions)
  failed for good: Stripe declined it or never completed it, and the money
  is still theirs to return (`Tymeslot.Emails.Templates.RefundFailed`).

  Enqueued by `Tymeslot.MeetingPayments.Refunds.FailureNotice` once the
  refund is settled `failed`. Loads the refund and its payment inside
  `perform/1`, and sends nothing once either is gone, or once the refund is
  no longer `failed`: Stripe reported it made after all
  (`Tymeslot.MeetingPayments.Refunds.FailureNotice.reversed/2`), and the
  money is the attendee's already. One job per refund, and the send is
  claimed through `Tymeslot.Workers.DeliveryClaims`, so a rescued job does
  not send it twice.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    priority: 0,
    unique: [keys: [:refund_id], states: :all, period: :infinity]

  require Logger

  alias Tymeslot.Emails.Templates.RefundFailed
  alias Tymeslot.Emails.Templates.RefundFailed.RefundContext
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @behaviour ExpectedJobOutcome

  @refund_gone "refund not found"
  @not_failed "refund no longer failed"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@refund_gone, @not_failed] or
        TransactionalEmailDelivery.recipient_rejected?(reason)

  @doc "The job telling the host that `refund` failed."
  @spec new_for(RefundSchema.t()) :: Oban.Job.changeset()
  def new_for(%RefundSchema{id: id}), do: new(%{refund_id: id})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refund_id" => id}} = job) do
    with %RefundSchema{} = refund <- MeetingPayments.get_refund(id),
         %BookingPaymentSchema{} = payment <-
           BookingPayments.get_payment(refund.booking_payment_id) do
      send_to_host(job, refund, payment)
    else
      nil -> {:discard, @refund_gone}
    end
  end

  defp send_to_host(_job, %RefundSchema{status: status} = refund, _payment)
       when status != :failed do
    Logger.info("Refund failure email skipped, the refund is no longer failed",
      refund_id: refund.id,
      status: status
    )

    {:cancel, @not_failed}
  end

  defp send_to_host(_job, refund, %BookingPaymentSchema{host_email: host_email})
       when host_email in [nil, ""] do
    Logger.warning("Refund failure email skipped, no host email", refund_id: refund.id)
    {:discard, "missing host_email"}
  end

  defp send_to_host(job, refund, payment) do
    DeliveryClaims.once(job, "refund_failed_email", fn ->
      refund
      |> context(payment)
      |> RefundFailed.render()
      |> TransactionalEmailDelivery.deliver(job, "Refund failure email failed",
        refund_id: refund.id,
        booking_payment_id: payment.id
      )
    end)
  end

  defp context(refund, payment) do
    # A series payment is named after its first session.
    meeting = payment |> BookingPayments.meetings_for_payment() |> List.first()

    %RefundContext{
      host_email: payment.host_email,
      host_name: payment.host_name,
      host_user_id: payment.host_user_id,
      amount_cents: refund.amount_cents,
      currency: payment.currency,
      attendee_name: payment.attendee_name,
      attendee_email: payment.attendee_email,
      meeting_title: meeting_title(meeting, payment),
      series_cancellation?: refund.source == :series_host
    }
  end

  defp meeting_title(%{title: title}, _payment) when is_binary(title) and title != "", do: title
  defp meeting_title(_meeting, %{meeting_type_name: name}) when is_binary(name), do: name
  defp meeting_title(_meeting, _payment), do: nil
end
