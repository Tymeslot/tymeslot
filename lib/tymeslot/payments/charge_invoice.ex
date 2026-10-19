defmodule Tymeslot.Payments.ChargeInvoice do
  @moduledoc """
  Finds the invoice a platform charge paid, and the subscription that invoice
  billed, asking Stripe for whatever the charge and the recorded invoices do
  not say.

  Two gaps make Stripe the only reliable source:

    * Invoices are recorded here only from when recording began, so an older
      invoice's subscription is unknown locally.
    * From API version 2025-03-31.basil a charge no longer names its invoice;
      the link runs from the invoice's payments to the charge's payment
      intent instead. Webhook bodies follow the endpoint's API version, and
      API reads follow the client's, so a charge may arrive in either shape.

  A Stripe failure is returned as an error, never guessed around: the answer
  decides which subscription a refund cancels, and a guess could cancel the
  wrong one.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments.Config
  alias Tymeslot.Payments.SubscriptionInvoices
  alias Tymeslot.Utils.MapKeys

  @typedoc """
  The invoice a charge paid and the subscription that invoice billed. Both
  are `nil` for a charge that paid no invoice; `subscription_id` alone is
  `nil` for an invoice that billed no subscription.
  """
  @type t :: %{invoice_id: String.t() | nil, subscription_id: String.t() | nil}

  @doc """
  Resolves the invoice and subscription a charge (a webhook body or an API
  read, string- or atom-keyed) paid for.
  """
  @spec for_charge(map()) :: {:ok, t()} | {:error, term()}
  def for_charge(charge) when is_map(charge) do
    case id_of(MapKeys.get(charge, :invoice)) do
      nil -> by_payment_intent(id_of(MapKeys.get(charge, :payment_intent)))
      invoice_id -> by_invoice(invoice_id)
    end
  end

  @doc """
  As `for_charge/1`, for a charge known only by its id, read from Stripe.
  """
  @spec for_charge_id(String.t()) :: {:ok, t()} | {:error, term()}
  def for_charge_id(charge_id) when is_binary(charge_id) do
    with {:ok, charge} <- stripe_call(& &1.get_charge(charge_id), charge_id: charge_id),
         do: for_charge(charge)
  end

  defp by_payment_intent(nil), do: {:ok, %{invoice_id: nil, subscription_id: nil}}

  defp by_payment_intent(payment_intent_id) do
    params = %{payment: %{type: "payment_intent", payment_intent: payment_intent_id}}

    with {:ok, page} <-
           stripe_call(& &1.list_invoice_payments(params), payment_intent_id: payment_intent_id) do
      case MapKeys.get(page, :data) || [] do
        [] -> {:ok, %{invoice_id: nil, subscription_id: nil}}
        [invoice_payment | _rest] -> by_invoice(id_of(MapKeys.get(invoice_payment, :invoice)))
      end
    end
  end

  defp by_invoice(nil), do: {:ok, %{invoice_id: nil, subscription_id: nil}}

  defp by_invoice(invoice_id) do
    case SubscriptionInvoices.subscription_id_for_invoice(invoice_id) do
      nil ->
        with {:ok, invoice} <- stripe_call(& &1.get_invoice(invoice_id), invoice_id: invoice_id),
             do: {:ok, %{invoice_id: invoice_id, subscription_id: subscription_of(invoice)}}

      subscription_id ->
        {:ok, %{invoice_id: invoice_id, subscription_id: subscription_id}}
    end
  end

  # API version 2025-03-31.basil moved the invoice's subscription reference
  # from the top-level field into parent.subscription_details.
  defp subscription_of(invoice) do
    id_of(
      MapKeys.get(invoice, :subscription) ||
        invoice
        |> map_field(:parent)
        |> map_field(:subscription_details)
        |> map_field(:subscription)
    )
  end

  defp map_field(map, key) when is_map(map), do: MapKeys.get(map, key)
  defp map_field(_value, _key), do: nil

  # A reference is an id, or the expanded object carrying it.
  defp id_of(id) when is_binary(id), do: id
  defp id_of(object) when is_map(object), do: MapKeys.get_binary(object, :id)
  defp id_of(_none), do: nil

  defp stripe_call(call, context) do
    case call.(Config.stripe_provider()) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Logger.error(
          "Stripe lookup for a charge's invoice failed",
          Keyword.put(context, :reason, LogFormat.reason(reason))
        )

        {:error, {:stripe_lookup_failed, reason}}
    end
  end
end
