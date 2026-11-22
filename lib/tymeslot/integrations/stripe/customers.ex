defmodule Tymeslot.Integrations.Stripe.Customers do
  @moduledoc """
  Stripe `Customers` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `create_customer`, `delete_customer`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`create_customer`."
  @spec create(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(params, opts),
    do: Client.run(Request.new(:create_customer, :post, ["customers"], params, opts))

  @doc "`delete_customer`."
  @spec delete(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete(id, opts),
    do: Client.run(Request.new(:delete_customer, :delete, ["customers", id], %{}, opts))
end
