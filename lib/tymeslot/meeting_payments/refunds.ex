defmodule Tymeslot.MeetingPayments.Refunds do
  @moduledoc """
  Issues refunds against `booking_payments` rows via the Stripe Refund
  API and reconciles the local row.

  The contract for `issue_refund/3`:

    * Validates the payment is within the 60-day refund window.
    * Validates the requested amount is positive and does not exceed
      the remaining refundable balance.
    * Calls Stripe with an idempotency key keyed on the payment id,
      cumulative refunded total after this refund, and the requested
      amount — so a true retry collapses while a fresh attempt at a
      different amount produces a fresh Stripe call.
    * Conditionally passes `refund_application_fee: true` only when
      the original charge had a non-zero application fee. Stripe
      errors if asked to refund a fee that was never collected.
    * Updates the local `booking_payments` row, transitioning status
      to `partially_refunded` or `refunded` based on the new total.
    * Synchronously enqueues an attendee refund email via
      `Tymeslot.Workers.SendBookingPaymentRefunded`.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  @refund_window_days 60

  @type refund_error ::
          :not_paid
          | :outside_refund_window
          | :already_refunded
          | :invalid_amount
          | :missing_charge
          | term()

  @spec issue_refund(BookingPaymentSchema.t(), pos_integer(), String.t() | nil) ::
          {:ok, BookingPaymentSchema.t()} | {:error, refund_error()}
  def issue_refund(payment, amount_cents, reason \\ nil) do
    with :ok <- validate_within_window(payment),
         :ok <- validate_amount(payment, amount_cents),
         :ok <- validate_charge(payment),
         {:ok, _stripe_refund} <- create_stripe_refund(payment, amount_cents, reason),
         {:ok, updated_payment} <- update_payment_after_refund(payment, amount_cents) do
      enqueue_refund_email(updated_payment)
      {:ok, updated_payment}
    end
  end

  defp validate_within_window(%{paid_at: nil}), do: {:error, :not_paid}

  defp validate_within_window(%{paid_at: %DateTime{} = paid_at}) do
    if DateTime.diff(DateTime.utc_now(), paid_at, :day) <= @refund_window_days do
      :ok
    else
      {:error, :outside_refund_window}
    end
  end

  defp validate_amount(%{status: "refunded"}, _amount_cents), do: {:error, :already_refunded}

  defp validate_amount(
         %{amount_cents: amount, refunded_amount_cents: refunded},
         amount_cents
       )
       when is_integer(amount_cents) and amount_cents > 0 and
              amount_cents <= amount - refunded,
       do: :ok

  defp validate_amount(_payment, _amount_cents), do: {:error, :invalid_amount}

  defp validate_charge(%{stripe_charge_id: charge}) when is_binary(charge) and charge != "",
    do: :ok

  defp validate_charge(_payment), do: {:error, :missing_charge}

  defp create_stripe_refund(payment, amount_cents, reason) do
    cumulative_after = payment.refunded_amount_cents + amount_cents

    base_params = %{
      charge: payment.stripe_charge_id,
      amount: amount_cents,
      reason: reason,
      metadata: %{
        meeting_id: payment.meeting_id,
        booking_payment_id: payment.id
      }
    }

    params =
      if (payment.application_fee_cents || 0) > 0 do
        Map.put(base_params, :refund_application_fee, true)
      else
        base_params
      end

    StripeAdapter.create_refund(params,
      connect_account: payment.stripe_account_id,
      idempotency_key: "refund:#{payment.id}:#{cumulative_after}:#{amount_cents}"
    )
  end

  defp update_payment_after_refund(payment, amount_cents) do
    new_total = payment.refunded_amount_cents + amount_cents

    new_status =
      cond do
        new_total >= payment.amount_cents -> "refunded"
        new_total > 0 -> "partially_refunded"
        true -> payment.status
      end

    BookingPaymentQueries.update(payment, %{
      refunded_amount_cents: new_total,
      status: new_status
    })
  end

  defp enqueue_refund_email(payment) do
    %{booking_payment_id: payment.id}
    |> SendBookingPaymentRefunded.new()
    |> Oban.insert()
  end
end
