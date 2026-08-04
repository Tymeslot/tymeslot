defmodule Tymeslot.Payments.Webhooks.InvoiceDocument do
  @moduledoc """
  Extracts the invoice document reference from a Stripe invoice payload.

  Stripe issues an invoice for every subscription charge and hosts both an HTML
  page and a PDF of it. Those are the customer's VAT documents, so we keep a
  pointer to them in the `subscription_invoices` table rather than sending
  people to the billing portal to hunt for them.
  """

  @doc """
  Extracts the invoice number, currency, and hosted document URLs from a
  Stripe invoice.

  Returns a map ready to merge into `Webhooks.InvoiceEvent`. Absent fields
  come back as `nil`: `SubscriptionInvoiceQueries.upsert/1` is what protects a
  captured document from being blanked by a later event that doesn't carry a
  given field, via its per-field `COALESCE`, so this extraction step doesn't
  need to drop anything itself.

  ## Examples

      iex> InvoiceDocument.extract(%{
      ...>   "number" => "A1B2C3-0001",
      ...>   "hosted_invoice_url" => "https://invoice.stripe.com/i/abc",
      ...>   "invoice_pdf" => "https://pay.stripe.com/invoice/abc/pdf",
      ...>   "currency" => "eur"
      ...> })
      %{
        invoice_number: "A1B2C3-0001",
        hosted_invoice_url: "https://invoice.stripe.com/i/abc",
        invoice_pdf_url: "https://pay.stripe.com/invoice/abc/pdf",
        currency: "eur"
      }

      iex> InvoiceDocument.extract(%{})
      %{invoice_number: nil, hosted_invoice_url: nil, invoice_pdf_url: nil, currency: nil}
  """
  @spec extract(map()) :: map()
  def extract(invoice) do
    %{
      invoice_number: invoice["number"],
      hosted_invoice_url: invoice["hosted_invoice_url"],
      invoice_pdf_url: invoice["invoice_pdf"],
      currency: invoice["currency"]
    }
  end
end
