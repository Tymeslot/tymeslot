defmodule Tymeslot.MeetingPayments.Webhooks.RefundUpdated do
  @moduledoc """
  Handler for the Stripe `refund.updated` Connect event (and the older
  `charge.refund.updated`, which carries the same refund object), sent when
  a refund changes after Stripe accepted it. A bank-backed refund can end
  `failed` or `canceled` days later, the money going back to the host,
  which `charge.refunded` never reports, as its total is never lowered.

  The refund is reconciled with its payment's recorded refunds
  (`Refunds.reconcile/2`): a refund recorded as made is taken off the
  refunded total and reported, a pending one is settled, one made in the
  Stripe dashboard is recorded. Every step acts only on a refund not yet in
  the state Stripe reports, so a replayed event does nothing.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @event_type "refund.updated"

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"data" => %{"object" => %{"charge" => charge_id} = refund}} = event)
       when is_binary(charge_id) do
    case PaymentLookup.find_for_charge(event, charge_id) do
      {:error, reason} ->
        {{:error, :retry_later, reason}, :error}

      nil ->
        Logger.info("refund.updated: no booking_payment matched",
          charge_id: charge_id,
          stripe_refund_id: refund["id"]
        )

        {:ok, :ok}

      payment ->
        case Refunds.reconcile(payment, [refund]) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {{:error, :retry_later, reason}, :error}
        end
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}
end
