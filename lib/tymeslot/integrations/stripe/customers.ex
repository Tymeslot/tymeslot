defmodule Tymeslot.Integrations.Stripe.Customers do
  @moduledoc """
  Stripe `Customers` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `create_customer`, `list_customers`, `delete_customer`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Creates a customer (POST /v1/customers).
  """
  @spec create(map() | keyword(), keyword()) :: Client.result()
  def create(params, opts \\ []) do
    Client.run(Request.new(:create_customer, :post, ["customers"], params, opts))
  end

  @doc """
  Lists customers (GET /v1/customers), newest first.
  """
  @spec list(map() | keyword(), keyword()) :: Client.result()
  def list(params, opts \\ []) do
    Client.run(Request.new(:list_customers, :get, ["customers"], params, opts))
  end

  @doc """
  Deletes a customer (DELETE /v1/customers/:id).
  """
  @spec delete(String.t(), keyword()) :: Client.result()
  def delete(id, opts \\ []) do
    Client.run(Request.new(:delete_customer, :delete, ["customers", id], %{}, opts))
  end
end
