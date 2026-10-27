defmodule Tymeslot.MeetingPayments.Webhooks.PaymentLookup do
  @moduledoc """
  Resolves the `booking_payment` a Connect webhook refers to, and refuses to
  hand it over unless the event came from the connected account the booking
  was charged on.

  The platform's Connect endpoint receives events from every connected
  account, including objects a host created on their own Standard account
  outside Tymeslot. Every key the handlers resolve a row by
  (`client_reference_id`, PaymentIntent metadata) can be set by whoever
  creates the object, so a row is only returned when `event["account"]`
  equals the row's `stripe_account_id`. Anything else is logged and answered
  with `nil`, which the handlers acknowledge so Stripe stops retrying.

  Checkout session events (`checkout.session.*`) resolve by:

    1. the session id, once `CheckoutSessions` has attached it to the row.
       Only the platform's own session creation can produce that value.
    2. `client_reference_id` (the meeting id), but only for a row with no
       session attached yet; a row whose stored session differs is someone
       else's session.

  Charge events (`charge.refunded`, `charge.dispute.*`) resolve by, cheapest
  first:

    1. `stripe_charge_id`, present once `checkout.session.completed` has
       backfilled it. The common case: real disputes and refunds arrive long
       after the booking is paid.
    2. `stripe_payment_intent_id`, written at checkout creation and by the
       completed handler, so it survives a failed charge-id backfill.
    3. `meeting_id` read from the PaymentIntent's metadata, the last resort
       for an event that races ahead of `checkout.session.completed`. It costs
       one Stripe API call and needs the connected-account id from the event.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter

  @doc """
  Resolves the row for a `checkout.session.*` event, or `nil`.
  """
  @spec find_for_session(map()) :: BookingPaymentSchema.t() | nil
  def find_for_session(%{"data" => %{"object" => object}} = event) do
    object
    |> session_payment()
    |> owned_by_event_account(event)
  end

  def find_for_session(_event), do: nil

  @doc """
  Resolves the row for a charge-based event, or `nil`. `charge_id` is the
  charge the event's object refers to (the object itself for a charge, its
  `charge` field for a dispute).
  """
  @spec find_for_charge(map(), String.t() | nil) :: BookingPaymentSchema.t() | nil
  def find_for_charge(%{"data" => %{"object" => object}} = event, charge_id) do
    intent_id = object["payment_intent"]

    payment =
      by_charge_id(charge_id) ||
        by_payment_intent_id(intent_id) ||
        by_metadata(intent_id, event["account"])

    owned_by_event_account(payment, event)
  end

  def find_for_charge(_event, _charge_id), do: nil

  defp owned_by_event_account(nil, _event), do: nil

  defp owned_by_event_account(
         %BookingPaymentSchema{stripe_account_id: account} = payment,
         %{"account" => account}
       )
       when is_binary(account),
       do: payment

  defp owned_by_event_account(%BookingPaymentSchema{} = payment, event) do
    Logger.warning("Connect webhook ignored: event account does not own the booking payment",
      event_id: event["id"],
      event_type: event["type"],
      event_account: event["account"],
      payment_id: payment.id,
      payment_account: payment.stripe_account_id
    )

    nil
  end

  defp session_payment(%{"id" => session_id} = object) when is_binary(session_id) do
    BookingPaymentQueries.by_checkout_session(session_id) || unattached_by_reference(object)
  end

  defp session_payment(object), do: unattached_by_reference(object)

  defp unattached_by_reference(%{"client_reference_id" => meeting_id})
       when is_binary(meeting_id) do
    case BookingPaymentQueries.by_meeting_id(meeting_id) do
      %BookingPaymentSchema{stripe_checkout_session_id: nil} = payment -> payment
      _attached_or_nil -> nil
    end
  end

  defp unattached_by_reference(_object), do: nil

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
          reason: LogFormat.reason(reason)
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
