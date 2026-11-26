defmodule Tymeslot.Integrations.Stripe.InvoicePayments do
  @moduledoc """
  Stripe `InvoicePayments` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `list_invoice_payments`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Lists invoice payments (GET /v1/invoice_payments); `Pagination` walks all pages.
  """
  @spec list(map() | keyword(), keyword()) :: Client.result()
  def list(params, opts \\ []) do
    Client.run(Request.new(:list_invoice_payments, :get, ["invoice_payments"], params, opts))
  end
end
