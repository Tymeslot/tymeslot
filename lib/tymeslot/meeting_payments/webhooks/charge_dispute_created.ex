defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated do
  @moduledoc """
  Handler for the Stripe `charge.dispute.created` Connect event.

  Transitions the matching booking_payment to `disputed` while preserving
  `refunded_amount_cents`, and enqueues the host dispute notification
  email so the host can act on the dispute in the Stripe dashboard.

  Idempotent on `last_event_id`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Workers.SendChargeDisputeOpened

  @event_type "charge.dispute.created"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}}) do
    case lookup_payment(object) do
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

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  defp lookup_payment(%{"charge" => charge_id}) when is_binary(charge_id) do
    BookingPaymentQueries.by_charge_id(charge_id)
  end

  defp lookup_payment(_object), do: nil

  defp mark_disputed(payment, event_id, object) do
    case BookingPaymentQueries.update(payment, %{status: "disputed", last_event_id: event_id}) do
      {:ok, updated} ->
        Telemetry.emit_status_changed(payment.status, updated.status, :webhook_dispute_created)
        enqueue_dispute_email(updated, object)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_dispute_email(payment, object) do
    %{
      booking_payment_id: payment.id,
      reason: object["reason"]
    }
    |> SendChargeDisputeOpened.new()
    |> Oban.insert()
  end
end
