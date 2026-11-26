defmodule Tymeslot.MeetingPayments.Webhooks.RefundUpdated do
  @moduledoc """
  Handler for the Stripe `refund.updated` Connect event (and the older
  `charge.refund.updated`, which carries the same refund object), sent when
  a refund changes after Stripe accepted it. A bank-backed refund can end
  `failed` or `canceled` days later, the money going back to the host,
  which `charge.refunded` never reports, as its total is never lowered.

  The refund is read again from Stripe with its charge expanded, so it is
  reconciled as it stands now and with the charge's refunded total
  (`Refunds.reconcile/2`): a refund recorded as made is taken off the
  refunded total and reported, a pending one is settled, one made in the
  Stripe dashboard is recorded. Every step acts only on a refund not yet in
  the state Stripe reports, so a replayed event does nothing.

  A read a redelivery may get past answers `:retry_later`. One Stripe
  refuses for good leaves only the event's copy, which carries no charge
  total: a refund it reports ended is still settled from it, as that needs
  none, and a committed one is left to the refund's attempts and
  `charge.refunded`.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.Integrations.Stripe.Refunds, as: StripeRefunds
  alias Tymeslot.MeetingPayments.RefundReconciliation
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
        with {:ok, refunds} <- current(refund, event),
             :ok <- Refunds.reconcile(payment, refunds) do
          {:ok, :ok}
        else
          {:error, reason} -> {{:error, :retry_later, reason}, :error}
        end
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}

  defp current(%{"id" => id} = refund, event) when is_binary(id) do
    case StripeRefunds.retrieve(id, %{expand: ["charge"]}, connect_account: event["account"]) do
      {:ok, current} ->
        {:ok, [current]}

      {:error, reason} = error ->
        if StripeError.retryable?(reason) do
          error
        else
          Logger.warning("refund.updated: the refund cannot be read again, reconciled as sent",
            stripe_refund_id: id,
            reason: LogFormat.reason(reason)
          )

          {:ok, Enum.filter([refund], &RefundReconciliation.ended?/1)}
        end
    end
  end

  defp current(_refund, _event), do: {:ok, []}
end
