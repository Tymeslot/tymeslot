defmodule Tymeslot.Integrations.Stripe.Refunds do
  @moduledoc """
  Stripe `Refunds` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `create_refund`, `list_refunds`, `retrieve_refund`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Creates a refund (POST /v1/refunds). Connect refunds pass `connect_account:`; pass an `idempotency_key:` from `IdempotencyKey.for_intent/3`.
  """
  @spec create(map() | keyword(), keyword()) :: Client.result()
  def create(params, opts \\ []) do
    Client.run(Request.new(:create_refund, :post, ["refunds"], params, opts))
  end

  @doc """
  Lists refunds (GET /v1/refunds); `Pagination` walks all pages.
  """
  @spec list(map() | keyword(), keyword()) :: Client.result()
  def list(params, opts \\ []) do
    Client.run(Request.new(:list_refunds, :get, ["refunds"], params, opts))
  end

  @doc """
  Retrieves a refund (GET /v1/refunds/:id).
  """
  @spec retrieve(String.t(), keyword()) :: Client.result()
  def retrieve(id, opts \\ []), do: retrieve(id, %{}, opts)

  @doc """
  Retrieves a refund (GET /v1/refunds/:id) with `params`, such as
  `%{expand: ["charge"]}`.
  """
  @spec retrieve(String.t(), map() | keyword(), keyword()) :: Client.result()
  def retrieve(id, params, opts) do
    Client.run(Request.new(:retrieve_refund, :get, ["refunds", id], params, opts))
  end
end
