defmodule Tymeslot.Integrations.Stripe.Invoices do
  @moduledoc """
  Stripe `Invoices` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `retrieve_invoice`, `list_invoices`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`retrieve_invoice`."
  @spec retrieve(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def retrieve(id, opts),
    do: Client.run(Request.new(:retrieve_invoice, :get, ["invoices", id], %{}, opts))

  @doc "`list_invoices`."
  @spec list(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list(params, opts),
    do: Client.run(Request.new(:list_invoices, :get, ["invoices"], params, opts))
end
