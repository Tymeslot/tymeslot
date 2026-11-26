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
  A Stripe failure a later attempt can get past is not a `nil`: it is
  returned as `{:error, reason}`, which the handlers answer with
  `:retry_later`, so Stripe redelivers the event rather than having it
  acknowledged unmatched.

  Checkout session events (`checkout.session.*`) resolve by:

    1. the session id, once `CheckoutSessions` has attached it to the row.
       Only the platform's own session creation can produce that value.
    2. `client_reference_id` (the meeting id, `series:<series id>` for a
       paid series, or `seat_hold:<hold id>` for a held group seat), but only
       for a row with no session attached yet; a row whose stored session
       differs is someone else's session.

  Charge events (`charge.refunded`, `charge.dispute.*`) resolve by, cheapest
  first:

    1. `stripe_charge_id`, present once `checkout.session.completed` has
       backfilled it. The common case: real disputes and refunds arrive long
       after the booking is paid.
    2. `stripe_payment_intent_id`, written by the completed handler (an open
       session names no PaymentIntent yet), so it survives a failed
       charge-id backfill.
    3. `seat_hold_id`, `series_id` or `meeting_id` read from the PaymentIntent's
       metadata, in that order (a seat's intent names its meeting too), the last resort
       for an event that races ahead of `checkout.session.completed`. It costs
       one Stripe API call and needs the connected-account id from the event.
       A failure no retry can fix (an unknown intent, a refused or missing
       key) matches nothing, with an admin alert, since the event then goes
       unrecorded; any other failure of the call is the lookup's error.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.Integrations.Stripe.PaymentIntents
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.SeatPaymentQueries

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
  `charge` field for a dispute). `{:error, reason}` when the PaymentIntent
  the last resort reads could not be read from Stripe, for a reason a
  redelivery may get past.
  """
  @spec find_for_charge(map(), String.t() | nil) ::
          BookingPaymentSchema.t() | nil | {:error, StripeError.t()}
  def find_for_charge(%{"data" => %{"object" => object}} = event, charge_id) do
    intent_id = object["payment_intent"]

    case by_charge_id(charge_id) || by_payment_intent_id(intent_id) ||
           by_metadata(event, intent_id, charge_id) do
      {:error, _reason} = error -> error
      payment -> owned_by_event_account(payment, event)
    end
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

  defp unattached_by_reference(%{"client_reference_id" => reference})
       when is_binary(reference) do
    case by_reference(reference) do
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

  defp by_metadata(%{"account" => account} = event, intent_id, charge_id)
       when is_binary(intent_id) and is_binary(account) do
    case PaymentIntents.retrieve(intent_id, %{}, connect_account: account) do
      {:ok, intent} ->
        intent |> reference_from_metadata() |> by_reference()

      {:error, reason} ->
        context = %{
          event_id: event["id"],
          event_type: event["type"],
          charge_id: charge_id,
          payment_intent_id: intent_id,
          stripe_account_id: account
        }

        unreadable_intent(StripeError.retryable?(reason), reason, context)
    end
  end

  defp by_metadata(_event, _intent_id, _charge_id), do: nil

  defp unreadable_intent(true = _retryable, reason, context) do
    Logger.warning(
      "payment lookup: could not retrieve payment intent for metadata match, retrying",
      Map.to_list(context) ++ [reason: LogFormat.reason(reason)]
    )

    {:error, reason}
  end

  # The event is acknowledged, as redelivering it would fail the same way
  # for the three days Stripe keeps trying, so whatever refund or dispute it
  # carries is recorded only by hand.
  defp unreadable_intent(false = _retryable, reason, context) do
    Logger.error(
      "payment lookup: payment intent unreadable for good, event acknowledged unmatched",
      Map.to_list(context) ++ [reason: LogFormat.reason(reason)]
    )

    AdminAlerts.report(:connect_event_unmatched,
      summary: "A Connect charge event could not be matched to a booking payment",
      reason: reason,
      context: context
    )

    nil
  end

  # A reference names the meeting a payment is for, or, prefixed, the series
  # or the seat hold. Strict on the owner: a meeting's own payment only,
  # never its series' or a seat's.
  defp by_reference("series:" <> series_id), do: BookingPaymentQueries.by_series_id(series_id)

  defp by_reference("seat_hold:" <> hold_id),
    do: SeatPaymentQueries.by_seat_hold_id(hold_id)

  defp by_reference(meeting_id) when is_binary(meeting_id) do
    case UUID.cast(meeting_id) do
      {:ok, uuid} -> BookingPaymentQueries.by_meeting_id(uuid)
      :error -> nil
    end
  end

  defp by_reference(nil), do: nil

  # Checkout copies the booking's reference into the PaymentIntent's metadata
  # (`payment_intent_data.metadata`), so it is there from the first charge
  # event on.
  defp reference_from_metadata(%{"metadata" => metadata}), do: metadata_reference(metadata)
  defp reference_from_metadata(_intent), do: nil

  defp metadata_reference(%{"seat_hold_id" => id}) when is_binary(id), do: "seat_hold:" <> id
  defp metadata_reference(%{"series_id" => id}) when is_binary(id), do: "series:" <> id
  defp metadata_reference(%{"meeting_id" => id}) when is_binary(id), do: id
  defp metadata_reference(_metadata), do: nil
end
