defmodule Tymeslot.Integrations.Stripe.Invoices do
  @moduledoc """
  Stripe `Invoices` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `retrieve_invoice`, `list_invoices`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Retrieves an invoice (GET /v1/invoices/:id).
  """
  @spec retrieve(String.t(), keyword()) :: Client.result()
  def retrieve(id, opts \\ []) do
    Client.run(Request.new(:retrieve_invoice, :get, ["invoices", id], %{}, opts))
  end

  @doc """
  Lists invoices (GET /v1/invoices); `Pagination` walks all pages.
  """
  @spec list(map() | keyword(), keyword()) :: Client.result()
  def list(params, opts \\ []) do
    Client.run(Request.new(:list_invoices, :get, ["invoices"], params, opts))
  end
end
