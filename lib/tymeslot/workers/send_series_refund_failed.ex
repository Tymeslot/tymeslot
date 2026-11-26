defmodule Tymeslot.Workers.SendSeriesRefundFailed do
  @moduledoc """
  Runs jobs queued before the release that brought in the refund outbox
  (`booking_payment_refunds`), and the ones
  `Tymeslot.MeetingPayments.Workers.SeriesHostRefund` (itself kept only for
  series refunds queued then) inserts when it gives up on a refund it could
  not record; delete both in the release after it. A refund that was
  recorded and then failed is announced per refund by
  `Tymeslot.Workers.SendRefundFailed`.

  Such a job tells the host that the refund of a series payment, made when
  they cancelled the series' remaining sessions, could not be made.

  A run sends that worker's email (`Tymeslot.Emails.Templates.RefundFailed`,
  worded for a series cancellation) for the job's `booking_payment_id` and
  `amount_cents`, and sends nothing once the payment is gone. The send is
  claimed through `Tymeslot.Workers.DeliveryClaims` under the claim such a
  job has always taken, so a rescued job does not send it twice.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5, priority: 0

  require Logger

  alias Tymeslot.Emails.Templates.RefundFailed
  alias Tymeslot.Emails.Templates.RefundFailed.RefundContext
  alias Tymeslot.Infrastructure.ExpectedJobOutcome

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @behaviour ExpectedJobOutcome

  @payment_gone "booking_payment not found"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do: reason == @payment_gone or TransactionalEmailDelivery.recipient_rejected?(reason)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => id, "amount_cents" => amount}} = job) do
    case BookingPayments.get_payment(id) do
      nil ->
        {:discard, @payment_gone}

      %BookingPaymentSchema{host_email: host_email} when host_email in [nil, ""] ->
        Logger.warning("Series refund failure email skipped, no host email",
          booking_payment_id: id
        )

        {:discard, "missing host_email"}

      %BookingPaymentSchema{} = payment ->
        DeliveryClaims.once(job, "series_refund_failed_email", fn ->
          payment
          |> context(amount)
          |> RefundFailed.render()
          |> TransactionalEmailDelivery.deliver(job, "Series refund failure email failed",
            booking_payment_id: payment.id
          )
        end)
    end
  end

  defp context(payment, amount_cents) do
    # A series payment is named after its first session.
    meeting = payment |> BookingPayments.meetings_for_payment() |> List.first()

    %RefundContext{
      host_email: payment.host_email,
      host_name: payment.host_name,
      host_user_id: payment.host_user_id,
      amount_cents: amount_cents,
      currency: payment.currency,
      attendee_name: payment.attendee_name,
      attendee_email: payment.attendee_email,
      meeting_title: meeting_title(meeting, payment),
      series_cancellation?: true
    }
  end

  defp meeting_title(%{title: title}, _payment) when is_binary(title) and title != "", do: title
  defp meeting_title(_meeting, %{meeting_type_name: name}) when is_binary(name), do: name
  defp meeting_title(_meeting, _payment), do: nil
end
