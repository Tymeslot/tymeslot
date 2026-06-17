defmodule Tymeslot.MeetingPayments.Webhooks.ChargeRefunded do
  @moduledoc """
  Handler for the Stripe `charge.refunded` Connect event.

  Reconciles `booking_payment.refunded_amount_cents` and `status` against
  the cumulative `amount_refunded` Stripe reports on the charge. Designed
  to be idempotent against the synchronous refund path (`Refunds.issue_refund/3`)
  — replaying the same event, or arriving after the local row has already
  been updated, is a safe no-op.

  Status transitions:
    * full refund (`amount_refunded == amount_cents`) → `refunded`
    * partial refund (0 < amount_refunded < amount_cents) → `partially_refunded`
    * `disputed` is preserved — refunds during a dispute reconciliation
      track the cumulative amount but never overwrite the dispute status
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.Repo

  @event_type "charge.refunded"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(
         %{"id" => event_id, "data" => %{"object" => %{"id" => charge_id} = object}} = event
       )
       when is_binary(charge_id) do
    case PaymentLookup.find(charge_id, object["payment_intent"], event["account"]) do
      nil ->
        Logger.info("charge.refunded: no booking_payment matched", charge_id: charge_id)
        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        amount_refunded = object["amount_refunded"] || 0
        classify(update_payment(payment, event_id, amount_refunded))
    end
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  defp update_payment(payment, event_id, amount_refunded) do
    result =
      Repo.transaction(fn ->
        case BookingPaymentQueries.get_for_update(payment.id) do
          {:ok, locked} ->
            # Re-check idempotency after acquiring the lock to avoid reprocessing
            # during a concurrent in-app refund race.
            if locked.last_event_id == event_id do
              :idempotent_replay
            else
              new_total = max(locked.refunded_amount_cents, amount_refunded)
              new_status = derive_status(locked, new_total)

              case BookingPaymentQueries.update(locked, %{
                     refunded_amount_cents: new_total,
                     status: new_status,
                     last_event_id: event_id
                   }) do
                {:ok, updated} ->
                  {locked.status, updated.status}

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end

          {:error, reason} ->
            Repo.rollback(reason)
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

  # Disputes own the status field — refund webhooks during a dispute only
  # record the running refund total without changing status.
  defp derive_status(%{status: "disputed"}, _new_total), do: "disputed"

  defp derive_status(%{amount_cents: amount_cents}, new_total) do
    cond do
      new_total >= amount_cents -> "refunded"
      new_total > 0 -> "partially_refunded"
      true -> "paid"
    end
  end
end
