defmodule Tymeslot.Payments.Webhooks.InvoiceEvent do
  @moduledoc """
  Normalises a raw Stripe invoice webhook payload into a struct.

  `Payments.SubscriptionInvoices` is the domain: it owns invoice-capture policy and
  renewal-transaction creation, and must never reach into a raw,
  string-keyed Stripe payload — that would point the dependency from domain
  outward to the webhook transport. This module is the normalisation point,
  built and used only from `Webhooks.InvoiceHandler`.
  """

  alias Tymeslot.Payments.CustomerLookup
  alias Tymeslot.Payments.Webhooks.InvoiceDocument

  @enforce_keys [:id]
  defstruct [
    :id,
    :customer_id,
    :subscription_id,
    :billing_reason,
    :number,
    :currency,
    :amount_cents,
    :amount_paid,
    :created,
    :issued_at,
    :hosted_url,
    :pdf_url,
    :metadata_user_id,
    :status,
    :paid_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t() | nil,
          subscription_id: String.t() | nil,
          billing_reason: String.t() | nil,
          number: String.t() | nil,
          currency: String.t() | nil,
          amount_cents: integer() | nil,
          amount_paid: integer() | nil,
          created: integer() | nil,
          issued_at: DateTime.t() | nil,
          hosted_url: String.t() | nil,
          pdf_url: String.t() | nil,
          metadata_user_id: pos_integer() | nil,
          status: String.t() | nil,
          paid_at: DateTime.t() | nil
        }

  @doc """
  Builds an invoice event from Stripe's payload.

  `subscription_id` is threaded in rather than re-derived here: the handler
  already resolves it for its own routing decisions (including the
  API-version fallback to `parent.subscription_details`), and duplicating
  that parsing here would risk the two copies drifting apart.

  `amount_cents` is the invoice's `total` — the final amount after discounts
  and tax, the number printed on the hosted page and PDF, and set as soon as
  Stripe finalises the invoice. `amount_paid` is kept separately: it reads 0
  until the invoice is actually paid, so it's unsuitable as the document's
  headline amount, but the pre-existing renewal-transaction logic keys its
  `amount` on it and that behaviour is preserved unchanged. `created` is
  likewise kept as the raw payload value for that same pre-existing renewal
  metadata, unrelated to `issued_at` below.

  `issued_at` prefers `status_transitions.finalized_at` — the moment Stripe
  generated the document, shown as the "date of issue" on the hosted invoice
  and PDF — falling back to `created` for the rare payload missing it.

  `status` is Stripe's own invoice status (`draft`, `open`, `paid`, `void` or
  `uncollectible`), read verbatim off every payload Stripe sends — it is
  never absent on a real invoice object. `paid_at` mirrors `issued_at`'s
  parsing but reads `status_transitions.paid_at`, with no fallback: unlike
  `finalized_at`, an invoice that hasn't been paid yet has no substitute
  timestamp to fall back to.

  `metadata_user_id` is read from the subscription metadata Stripe echoes
  onto every invoice for that subscription — `parent.subscription_details.metadata`
  (2025-03-31.basil and later) or `subscription_details.metadata` (earlier
  API versions), mirroring the subscription-id fallback the handler already
  performs. It carries whatever `SubscriptionManager.create_checkout_session/6`
  set as `subscription_data.metadata["user_id"]` at checkout time, so it is
  available immediately, before any local `payment_transactions` or
  subscription row exists — unlike every other ownership signal
  `CustomerLookup.find_user_id/1` tries, which all depend on a row that
  webhook delivery may race ahead of.
  """
  @spec from_payload(map(), String.t() | nil) :: t()
  def from_payload(invoice, subscription_id) do
    document = InvoiceDocument.extract(invoice)

    %__MODULE__{
      id: invoice["id"],
      customer_id: reference_id(invoice["customer"]),
      subscription_id: subscription_id,
      billing_reason: invoice["billing_reason"],
      number: document[:invoice_number],
      currency: document[:currency],
      amount_cents: invoice["total"],
      amount_paid: invoice["amount_paid"],
      created: invoice["created"],
      issued_at: issued_at(invoice),
      hosted_url: document[:hosted_invoice_url],
      pdf_url: document[:invoice_pdf_url],
      metadata_user_id: metadata_user_id(invoice),
      status: invoice["status"],
      paid_at: unix_to_datetime(get_in(invoice, ["status_transitions", "paid_at"]))
    }
  end

  defp reference_id(%{"id" => id}), do: id
  defp reference_id(id), do: id

  defp metadata_user_id(invoice) do
    metadata =
      get_in(invoice, ["parent", "subscription_details", "metadata"]) ||
        get_in(invoice, ["subscription_details", "metadata"]) || %{}

    metadata
    |> Map.get("user_id")
    |> CustomerLookup.parse_user_id()
  end

  defp issued_at(invoice) do
    unix = get_in(invoice, ["status_transitions", "finalized_at"]) || invoice["created"]
    unix_to_datetime(unix)
  end

  defp unix_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
  defp unix_to_datetime(_other), do: nil
end
