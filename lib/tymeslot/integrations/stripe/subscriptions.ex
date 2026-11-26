defmodule Tymeslot.Integrations.Stripe.Subscriptions do
  @moduledoc """
  Stripe `Subscriptions` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `create_subscription`, `retrieve_subscription`, `list_subscriptions`, `update_subscription`, `cancel_subscription`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Creates a subscription (POST /v1/subscriptions). No feature uses this yet; the live test suite does.
  """
  @spec create(map() | keyword(), keyword()) :: Client.result()
  def create(params, opts \\ []) do
    Client.run(Request.new(:create_subscription, :post, ["subscriptions"], params, opts))
  end

  @doc """
  Retrieves a subscription (GET /v1/subscriptions/:id).
  """
  @spec retrieve(String.t(), keyword()) :: Client.result()
  def retrieve(id, opts \\ []) do
    Client.run(Request.new(:retrieve_subscription, :get, ["subscriptions", id], %{}, opts))
  end

  @doc """
  Lists subscriptions (GET /v1/subscriptions); `Pagination` walks all pages.
  """
  @spec list(map() | keyword(), keyword()) :: Client.result()
  def list(params, opts \\ []) do
    Client.run(Request.new(:list_subscriptions, :get, ["subscriptions"], params, opts))
  end

  @doc """
  Updates a subscription (POST /v1/subscriptions/:id).
  """
  @spec update(String.t(), map() | keyword(), keyword()) :: Client.result()
  def update(id, params, opts \\ []) do
    Client.run(Request.new(:update_subscription, :post, ["subscriptions", id], params, opts))
  end

  @doc """
  Cancels a subscription immediately (DELETE /v1/subscriptions/:id); `params` may carry `invoice_now` and `prorate`.
  """
  @spec cancel(String.t(), map() | keyword(), keyword()) :: Client.result()
  def cancel(id, params, opts \\ []) do
    Client.run(Request.new(:cancel_subscription, :delete, ["subscriptions", id], params, opts))
  end
end
