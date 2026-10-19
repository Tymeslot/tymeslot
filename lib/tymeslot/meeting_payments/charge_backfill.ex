defmodule Tymeslot.MeetingPayments.ChargeBackfill do
  @moduledoc """
  Records a booking payment's Stripe charge id, which refunds need and the
  `charge.refunded` and `charge.dispute.*` handlers look the row up by.

  `checkout.session.completed` carries the payment intent as a bare id; the
  charge is its `latest_charge`, which only an expanded retrieval from Stripe
  returns. That is a Stripe call, so it is never made inside a transaction.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter

  @doc """
  Fetches the charge id of `intent_id` from the payment's connected account
  and stores it on `payment`.

  Returns the updated payment, or `{:error, :missing_payment_intent}` when
  there is no intent id, `{:error, :charge_not_available}` when the intent
  carries no charge (yet), or the error from Stripe or the update.
  """
  @spec backfill(BookingPaymentSchema.t(), String.t() | nil) ::
          {:ok, BookingPaymentSchema.t()} | {:error, term()}
  def backfill(_payment, intent_id) when not is_binary(intent_id),
    do: {:error, :missing_payment_intent}

  def backfill(payment, intent_id) do
    with {:ok, intent} <-
           StripeAdapter.retrieve_payment_intent(intent_id,
             connect_account: payment.stripe_account_id
           ),
         {:ok, charge_id} <- charge_id(intent) do
      BookingPaymentQueries.update(payment, %{stripe_charge_id: charge_id})
    end
  end

  # The mock adapter yields string-keyed maps, as a webhook event arrives;
  # the real Stripity adapter returns an atom-keyed `%Stripe.PaymentIntent{}`
  # whose expanded `latest_charge` is a `%Stripe.Charge{}` struct. Handle both
  # so the charge id is captured regardless of adapter.
  defp charge_id(%{"latest_charge" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp charge_id(%{"latest_charge" => id}) when is_binary(id), do: {:ok, id}
  defp charge_id(%{latest_charge: %{id: id}}) when is_binary(id), do: {:ok, id}
  defp charge_id(%{latest_charge: id}) when is_binary(id), do: {:ok, id}
  defp charge_id(_intent), do: {:error, :charge_not_available}
end
