defmodule Tymeslot.MeetingPayments.Webhooks.PaymentLookup do
  @moduledoc """
  Resolves the `booking_payment` a charge-based Connect webhook
  (`charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`)
  refers to.

  Matching strategy, cheapest first:

    1. `stripe_charge_id` — present once `checkout.session.completed` has
       backfilled it. The common case: real disputes and refunds arrive long
       after the booking is paid.
    2. `stripe_payment_intent_id` — written by the completed handler straight
       from the event, so it survives even when the charge-id backfill (an
       extra Stripe call) failed.
    3. `meeting_id` read from the PaymentIntent's metadata — the last resort
       for an event that races ahead of `checkout.session.completed`, before
       either id is linked to the row. We stamp `meeting_id` into every
       session's PaymentIntent metadata at checkout creation, so this resolves
       the booking regardless of webhook ordering. It costs one Stripe API
       call and needs the connected-account id from the event.

  Returns `nil` only for events that belong to no Tymeslot booking — e.g. a
  charge a host created outside Tymeslot on their Standard account.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter

  @spec find(String.t() | nil, String.t() | nil, String.t() | nil) ::
          BookingPaymentSchema.t() | nil
  def find(charge_id, payment_intent_id, connect_account) do
    by_charge_id(charge_id) ||
      by_payment_intent_id(payment_intent_id) ||
      by_metadata(payment_intent_id, connect_account)
  end

  defp by_charge_id(charge_id) when is_binary(charge_id),
    do: BookingPaymentQueries.by_charge_id(charge_id)

  defp by_charge_id(_charge_id), do: nil

  defp by_payment_intent_id(intent_id) when is_binary(intent_id),
    do: BookingPaymentQueries.by_payment_intent_id(intent_id)

  defp by_payment_intent_id(_intent_id), do: nil

  defp by_metadata(intent_id, connect_account)
       when is_binary(intent_id) and is_binary(connect_account) do
    case StripeAdapter.retrieve_payment_intent(intent_id, connect_account: connect_account) do
      {:ok, intent} ->
        case meeting_id_from_metadata(intent) do
          nil -> nil
          meeting_id -> BookingPaymentQueries.by_meeting_id(meeting_id)
        end

      {:error, reason} ->
        Logger.warning("payment lookup: could not retrieve payment intent for metadata match",
          payment_intent_id: intent_id,
          reason: inspect(reason)
        )

        nil
    end
  end

  defp by_metadata(_intent_id, _connect_account), do: nil

  # Stripe metadata keys are always strings; the PaymentIntent itself may be an
  # atom-keyed Stripity struct (real adapter) or a string-keyed map (mock).
  defp meeting_id_from_metadata(%{metadata: %{"meeting_id" => id}}) when is_binary(id), do: id
  defp meeting_id_from_metadata(%{"metadata" => %{"meeting_id" => id}}) when is_binary(id), do: id
  defp meeting_id_from_metadata(_intent), do: nil
end
