defmodule Tymeslot.Payments.Webhooks.InvoiceDocumentTest do
  use ExUnit.Case, async: true
  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.Payments.Webhooks.InvoiceDocument

  doctest InvoiceDocument

  describe "extract/1" do
    test "maps Stripe's invoice fields onto an invoice event map" do
      invoice = %{
        "number" => "A1B2C3-0001",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/abc",
        "invoice_pdf" => "https://pay.stripe.com/invoice/abc/pdf",
        "currency" => "eur"
      }

      assert InvoiceDocument.extract(invoice) == %{
               invoice_number: "A1B2C3-0001",
               hosted_invoice_url: "https://invoice.stripe.com/i/abc",
               invoice_pdf_url: "https://pay.stripe.com/invoice/abc/pdf",
               currency: "eur"
             }
    end

    test "returns absent fields as nil for an invoice carrying no document" do
      # SubscriptionInvoiceQueries.upsert/1's per-field COALESCE, not this
      # extraction step, is what stops a nil here from blanking a document an
      # earlier event already captured.
      assert InvoiceDocument.extract(%{"id" => "in_123"}) == %{
               invoice_number: nil,
               hosted_invoice_url: nil,
               invoice_pdf_url: nil,
               currency: nil
             }
    end
  end
end
