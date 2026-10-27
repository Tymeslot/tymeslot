defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated do
  @moduledoc """
  Handler for the Stripe `charge.dispute.created` Connect event.

  Transitions the matching booking_payment to `disputed` while preserving
  `refunded_amount_cents`, and enqueues the host dispute notification
  email so the host can act on the dispute in the Stripe dashboard.

  Idempotent on `last_event_id`.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.Payments.Behaviours.WebhookHandler
  alias Tymeslot.Workers.SendChargeDisputeOpened

  @event_type "charge.dispute.created"

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case PaymentLookup.find_for_charge(event, object["charge"]) do
      nil ->
        Logger.info("charge.dispute.created: no booking_payment matched",
          charge_id: object["charge"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        classify(mark_disputed(payment, event_id, object))
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, reason}), do: {{:error, :retry_later, reason}, :error}

  # Written to the locked row (`LockedPayment`); the email is enqueued only
  # once the dispute status has committed, and not at all for a replay.
  defp mark_disputed(payment, event_id, object) do
    result =
      LockedPayment.run(payment, event_id, fn locked ->
        case BookingPaymentQueries.update(locked, %{status: "disputed", last_event_id: event_id}) do
          {:ok, updated} -> {:ok, {locked.status, updated}}
          {:error, _changeset} = error -> error
        end
      end)

    case result do
      {:ok, :idempotent_replay} ->
        :ok

      {:ok, {old_status, updated}} ->
        Telemetry.emit_status_changed(old_status, updated.status, :webhook_dispute_created)
        enqueue_dispute_email(updated, object)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_dispute_email(payment, object) do
    case %{
           booking_payment_id: payment.id,
           reason: object["reason"]
         }
         |> SendChargeDisputeOpened.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue dispute email",
          booking_payment_id: payment.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
