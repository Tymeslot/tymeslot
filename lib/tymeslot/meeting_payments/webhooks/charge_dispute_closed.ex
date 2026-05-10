defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed do
  @moduledoc """
  Handler for the Stripe `charge.dispute.closed` Connect event.

  Reconciles status after a dispute is decided:

    * `won` → revert to `paid` (or `partially_refunded` if any prior
      refund was on the row before the dispute opened)
    * `lost` → set `refunded_amount_cents` to the disputed amount and
      derive `refunded` / `partially_refunded` accordingly. Stripe debits
      the host's balance for the disputed amount when a dispute is lost,
      so the row should reflect the funds being gone from the host's
      perspective.
    * other statuses (`warning_closed`, `warning_under_review`, …) are
      not decisive — leave the booking in `disputed` and ignore.

  Idempotent on `last_event_id`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry

  @event_type "charge.dispute.closed"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}}) do
    case lookup_payment(object) do
      nil ->
        Logger.info("charge.dispute.closed: no booking_payment matched",
          charge_id: object["charge"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        classify(apply_outcome(payment, event_id, object["status"], object["amount"] || 0))
    end
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  defp lookup_payment(%{"charge" => charge_id}) when is_binary(charge_id) do
    BookingPaymentQueries.by_charge_id(charge_id)
  end

  defp lookup_payment(_object), do: nil

  defp apply_outcome(payment, event_id, "won", _amount) do
    new_status = derive_status_from_refund(payment, payment.refunded_amount_cents)

    update(payment, event_id, %{status: new_status})
  end

  defp apply_outcome(payment, event_id, "lost", disputed_amount) do
    new_total = max(payment.refunded_amount_cents, disputed_amount)
    new_status = derive_status_from_refund(%{payment | refunded_amount_cents: 0}, new_total)

    update(payment, event_id, %{
      status: new_status,
      refunded_amount_cents: new_total
    })
  end

  defp apply_outcome(_payment, _event_id, _status, _amount), do: :ok

  defp derive_status_from_refund(%{amount_cents: amount_cents}, refunded) do
    cond do
      refunded >= amount_cents -> "refunded"
      refunded > 0 -> "partially_refunded"
      true -> "paid"
    end
  end

  defp update(payment, event_id, attrs) do
    case BookingPaymentQueries.update(payment, Map.put(attrs, :last_event_id, event_id)) do
      {:ok, updated} ->
        Telemetry.emit_status_changed(payment.status, updated.status, :webhook_dispute_closed)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
