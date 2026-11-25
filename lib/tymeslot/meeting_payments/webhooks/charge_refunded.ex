defmodule Tymeslot.MeetingPayments.Webhooks.ChargeRefunded do
  @moduledoc """
  Handler for the Stripe `charge.refunded` Connect event.

  First reconciles the payment's recorded refunds with the charge's refunds
  (`Refunds.reconcile/2`): a refund an attempt left pending is settled, one
  made in the Stripe dashboard is recorded. The refunds come embedded in the
  charge at older API versions and are listed from Stripe otherwise; a list
  a redelivery may get past answers `:retry_later`, one Stripe refuses for
  good is logged and the reconcile skipped.

  Then records the cumulative `amount_refunded` Stripe reports on the
  charge as the payment's refunds made (`stripe_refunded_cents`), and sets
  `refunded_amount_cents` and `status` from them: the charge counts
  refunds only, so what a lost dispute took is added (`RefundedTotal`).
  The refunds are never lowered here, so a late or replayed event cannot
  undo a refund recorded since; only `refund.updated` takes a failed
  refund off.
  Nor may a late report put one back: refunds Stripe has since reported
  ended are taken off the reported total (`Refunds.stale_committed_cents/2`)
  under the payment's row lock, so a refund failed between the report's
  reading and the write is not counted again. Listed refunds are read before
  the lock too, so the same holds for them.
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
        with {:ok, refunds, charge_total} <- charge_refunds(event, object, payment),
             :ok <- Refunds.reconcile(payment, refunds) do
          classify(update_payment(payment, event_id, refunds, charge_total))
        else
          {:error, reason} -> {{:error, :retry_later, reason}, :error}
        end
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}

  # The charge's refunds and its refunded total as Stripe reported them.
  # Each refund carries its charge, whose `amount_refunded` is the total a
  # refund settled from it records (`Refunds.Settlement.settle_succeeded/2`):
  # refunds embedded in the event are given the event's charge, its total
  # less what Stripe has ended since, and listed ones are listed with theirs
  # expanded.
  defp charge_refunds(_event, %{"refunds" => %{"data" => refunds}} = object, payment)
       when is_list(refunds) do
    total = event_total(object)

    charge =
      object
      |> Map.delete("refunds")
      |> Map.put("amount_refunded", current_total(payment, refunds, total))

    {:ok, Enum.map(refunds, &Map.put(&1, "charge", charge)), total}
  end

  defp charge_refunds(event, %{"id" => charge_id} = object, _payment) do
    params = %{charge: charge_id, limit: @refunds_listed, expand: ["data.charge"]}

    case StripeRefunds.list(params, connect_account: event["account"]) do
      {:ok, %{"data" => refunds}} when is_list(refunds) ->
        {:ok, refunds, Enum.find_value(refunds, &listed_total/1) || event_total(object)}

      {:error, reason} = error ->
        if StripeError.retryable?(reason) do
          error
        else
          Logger.warning("charge.refunded: the charge's refunds cannot be listed, not reconciled",
            charge_id: charge_id,
            reason: LogFormat.reason(reason)
          )

          {:ok, [], event_total(object)}
        end
    end
  end

  defp listed_total(%{"charge" => %{"amount_refunded" => total}}) when is_integer(total),
    do: total

  defp listed_total(_refund), do: nil

  defp event_total(object), do: object["amount_refunded"] || 0

  # `total`, reported with `refunds`, less the refunds it counts that Stripe
  # has reported ended since. Only refunds recorded as ended come off: a
  # dashboard refund the charge total alone counts stays in it.
  defp current_total(payment, refunds, total),
    do: max(total - Refunds.stale_committed_cents(payment, refunds), 0)

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, reason}), do: {{:error, :retry_later, reason}, :error}

  # Decided from the locked row (`LockedPayment`), so a concurrent refund
  # or dispute handler cannot have its committed amount written over, and
  # a refund failed since `refunds` were read is already recorded as failed.
  defp update_payment(payment, event_id, refunds, charge_total) do
    result =
      LockedPayment.run(payment, event_id, fn locked ->
        amount_refunded = current_total(locked, refunds, charge_total)
        figures = RefundedTotal.with_stripe_refunded(locked, amount_refunded)

        case BookingPaymentQueries.update(locked, Map.put(figures, :last_event_id, event_id)) do
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
