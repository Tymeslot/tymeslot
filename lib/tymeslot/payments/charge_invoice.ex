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
  alias Tymeslot.Integrations.Stripe.{Charges, InvoicePayments, Invoices}
  alias Tymeslot.Payments.SubscriptionInvoices

  @typedoc """
  The invoice a charge paid and the subscription that invoice billed. Both
  are `nil` for a charge that paid no invoice; `subscription_id` alone is
  `nil` for an invoice that billed no subscription.
  """
  @type t :: %{invoice_id: String.t() | nil, subscription_id: String.t() | nil}

  @doc """
  Resolves the invoice and subscription a charge (a webhook body or an API
  read, both string-keyed as Stripe sent them) paid for.
  """
  @spec for_charge(map()) :: {:ok, t()} | {:error, term()}
  def for_charge(charge) when is_map(charge) do
    case id_of(charge["invoice"]) do
      nil -> by_payment_intent(id_of(charge["payment_intent"]))
      invoice_id -> by_invoice(invoice_id)
    end
  end

  @doc """
  As `for_charge/1`, for a charge known only by its id, read from Stripe.
  """
  @spec for_charge_id(String.t()) :: {:ok, t()} | {:error, term()}
  def for_charge_id(charge_id) when is_binary(charge_id) do
    with {:ok, charge} <-
           stripe_call(fn -> Charges.retrieve(charge_id, []) end, charge_id: charge_id),
         do: for_charge(charge)
  end

  defp by_payment_intent(nil), do: {:ok, %{invoice_id: nil, subscription_id: nil}}

  defp by_payment_intent(payment_intent_id) do
    params = %{payment: %{type: "payment_intent", payment_intent: payment_intent_id}}

    with {:ok, page} <-
           stripe_call(fn -> InvoicePayments.list(params, []) end,
             payment_intent_id: payment_intent_id
           ) do
      case page["data"] || [] do
        [] -> {:ok, %{invoice_id: nil, subscription_id: nil}}
        [invoice_payment | _rest] -> by_invoice(id_of(invoice_payment["invoice"]))
      end
    end
  end

  defp by_invoice(nil), do: {:ok, %{invoice_id: nil, subscription_id: nil}}

  defp by_invoice(invoice_id) do
    case SubscriptionInvoices.subscription_id_for_invoice(invoice_id) do
      nil ->
        with {:ok, invoice} <-
               stripe_call(fn -> Invoices.retrieve(invoice_id, []) end,
                 invoice_id: invoice_id
               ),
             do: {:ok, %{invoice_id: invoice_id, subscription_id: subscription_of(invoice)}}

      subscription_id ->
        {:ok, %{invoice_id: invoice_id, subscription_id: subscription_id}}
    end
  end

  # API version 2025-03-31.basil moved the invoice's subscription reference
  # from the top-level field into parent.subscription_details.
  defp subscription_of(invoice) do
    id_of(
      invoice["subscription"] ||
        get_in(invoice, ["parent", "subscription_details", "subscription"])
    )
  end

  # A reference is an id, or the expanded object carrying it.
  defp id_of(id) when is_binary(id), do: id
  defp id_of(%{"id" => id}) when is_binary(id), do: id
  defp id_of(_none), do: nil

  defp stripe_call(call, context) do
    case call.() do
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
