defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated do
  @moduledoc """
  Handler for the Stripe `charge.dispute.created` Connect event.

  Transitions the matching booking_payment to `disputed` while preserving
  `refunded_amount_cents`. The host email notifying them of the dispute
  is wired in Chunk 6 once the email template ships — for now this
  handler only records the status change, which is enough to drive the
  dashboard "Disputed" filter and disable the refund button.

  Idempotent on `last_event_id`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(%{"id" => event_id, "data" => %{"object" => object}}) do
    case lookup_payment(object) do
      nil ->
        Logger.info("charge.dispute.created: no booking_payment matched",
          charge_id: object["charge"]
        )

        :ok

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        :ok

      payment ->
        mark_disputed(payment, event_id)
    end
  end

  def handle(_other), do: {:error, :invalid_event}

  defp lookup_payment(%{"charge" => charge_id}) when is_binary(charge_id) do
    BookingPaymentQueries.by_charge_id(charge_id)
  end

  defp lookup_payment(_object), do: nil

  defp mark_disputed(payment, event_id) do
    case BookingPaymentQueries.update(payment, %{status: "disputed", last_event_id: event_id}) do
      {:ok, _bp} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
