defmodule Tymeslot.Payments.SubscriptionInvoice do
  @moduledoc """
  Public read model for a customer-facing platform subscription invoice.

  This struct, and `Tymeslot.Payments.list_subscription_invoices/2` which
  returns it, are the stable contract callers across the repo boundary (the
  SaaS billing dashboard) code against — not `SubscriptionInvoiceSchema`,
  which is an implementation detail of this context. A field rename on the
  schema must never be able to break every caller that just wants to show
  someone their VAT documents.

  `status` is additive: every invoice this struct is built from is already
  `:paid` (see `SubscriptionInvoiceQueries.list_for_user/2`), so existing
  callers that ignore the field see no behavioural change.
  """

  alias Tymeslot.Payments.SubscriptionInvoiceSchema

  @enforce_keys [:number, :issued_at, :amount_cents, :currency, :hosted_url, :pdf_url]
  defstruct @enforce_keys ++ [:status]

  @type t :: %__MODULE__{
          number: String.t() | nil,
          issued_at: DateTime.t() | nil,
          amount_cents: integer() | nil,
          currency: String.t() | nil,
          hosted_url: String.t() | nil,
          pdf_url: String.t() | nil,
          status: :draft | :open | :paid | :void | :uncollectible | nil
        }

  @doc """
  Builds an invoice read model from a captured invoice.
  """
  @spec from_schema(SubscriptionInvoiceSchema.t()) :: t()
  def from_schema(%SubscriptionInvoiceSchema{} = invoice) do
    %__MODULE__{
      number: invoice.number,
      issued_at: invoice.issued_at,
      amount_cents: invoice.amount_cents,
      currency: invoice.currency,
      hosted_url: invoice.hosted_invoice_url,
      pdf_url: invoice.invoice_pdf_url,
      status: invoice.status
    }
  end
end
