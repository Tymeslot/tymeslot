defmodule Tymeslot.MeetingPayments.Webhooks.ChargeRefunded do
  @moduledoc """
  Handler for the Stripe `charge.refunded` Connect event.

  First reconciles the payment's recorded refunds with the charge's refunds
  (`Refunds.reconcile/2`): a refund an attempt left pending is settled, one
  made in the Stripe dashboard is recorded. The refunds come embedded in the
  charge at older API versions and are listed from Stripe otherwise; a list
  a redelivery may get past answers `:retry_later`, one Stripe refuses for
  good is logged and the reconcile skipped.

  Then sets `booking_payment.refunded_amount_cents` and `status` from the
  cumulative `amount_refunded` Stripe reports on the charge, which counts
  refunds only: what a lost dispute took is added to it (`RefundedTotal`).
  The total is never lowered here, so a late or replayed event cannot undo
  a refund recorded since; only `refund.updated` takes a failed refund off.
  The reconcile runs first because the event id is recorded with the
  total: a redelivery after a failed reconcile repeats both, and one after
  success is a no-op.

  Status transitions:
    * full refund (`amount_refunded == amount_cents`) → `refunded`
    * partial refund (0 < amount_refunded < amount_cents) → `partially_refunded`
    * `disputed` is preserved — refunds during a dispute reconciliation
      track the cumulative amount but never overwrite the dispute status
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.Integrations.Stripe.Refunds, as: StripeRefunds
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @event_type "charge.refunded"

  # One page; a booking payment sees nowhere near this many refunds.
  @refunds_listed 100

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(
         %{"id" => event_id, "data" => %{"object" => %{"id" => charge_id} = object}} = event
       )
       when is_binary(charge_id) do
    case PaymentLookup.find_for_charge(event, charge_id) do
      {:error, reason} ->
        {{:error, :retry_later, reason}, :error}

      nil ->
        Logger.info("charge.refunded: no booking_payment matched", charge_id: charge_id)
        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        with {:ok, refunds} <- charge_refunds(event, object),
             :ok <- Refunds.reconcile(payment, refunds) do
          classify(update_payment(payment, event_id, object["amount_refunded"] || 0))
        else
          {:error, reason} -> {{:error, :retry_later, reason}, :error}
        end
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}

  # Each refund carries its charge, whose `amount_refunded` is the total a
  # refund settled from it records (`Refunds.Settlement.settle_succeeded/2`):
  # refunds embedded in the event are given the event's charge, from the
  # same moment, and listed ones are listed with theirs expanded.
  defp charge_refunds(_event, %{"refunds" => %{"data" => refunds}} = object)
       when is_list(refunds) do
    charge = Map.delete(object, "refunds")
    {:ok, Enum.map(refunds, &Map.put(&1, "charge", charge))}
  end

  defp charge_refunds(event, %{"id" => charge_id}) do
    params = %{charge: charge_id, limit: @refunds_listed, expand: ["data.charge"]}

    case StripeRefunds.list(params, connect_account: event["account"]) do
      {:ok, %{"data" => refunds}} when is_list(refunds) ->
        {:ok, refunds}

      {:error, reason} = error ->
        if StripeError.retryable?(reason) do
          error
        else
          Logger.warning("charge.refunded: the charge's refunds cannot be listed, not reconciled",
            charge_id: charge_id,
            reason: LogFormat.reason(reason)
          )

          {:ok, []}
        end
    end
  end

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, reason}), do: {{:error, :retry_later, reason}, :error}

  # Decided from the locked row (`LockedPayment`), so a concurrent refund
  # or dispute handler cannot have its committed amount written over.
  defp update_payment(payment, event_id, amount_refunded) do
    result =
      LockedPayment.run(payment, event_id, fn locked ->
        new_total = RefundedTotal.with_stripe_refunded(locked, amount_refunded)

        case BookingPaymentQueries.update(locked, %{
               refunded_amount_cents: new_total,
               status: RefundedTotal.status_for(locked, new_total),
               last_event_id: event_id
             }) do
          {:ok, updated} -> {:ok, {locked.status, updated.status}}
          {:error, _changeset} = error -> error
        end
      end)

    case result do
      {:ok, :idempotent_replay} ->
        :ok

      {:ok, {old_status, new_status}} ->
        Telemetry.emit_status_changed(old_status, new_status, :webhook_charge_refunded)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
