defmodule Tymeslot.Integrations.Stripe.Subscriptions do
  @moduledoc """
  Stripe `Subscriptions` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `create_subscription`, `retrieve_subscription`, `list_subscriptions`, `update_subscription`, `cancel_subscription`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`create_subscription`. No feature uses this yet; the live test suite does."
  @spec create(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(params, opts),
    do: Client.run(Request.new(:create_subscription, :post, ["subscriptions"], params, opts))

  @doc "`retrieve_subscription`."
  @spec retrieve(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def retrieve(id, opts),
    do: Client.run(Request.new(:retrieve_subscription, :get, ["subscriptions", id], %{}, opts))

  @doc "`list_subscriptions`."
  @spec list(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list(params, opts),
    do: Client.run(Request.new(:list_subscriptions, :get, ["subscriptions"], params, opts))

  @doc "`update_subscription`."
  @spec update(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update(id, params, opts),
    do: Client.run(Request.new(:update_subscription, :post, ["subscriptions", id], params, opts))

  @doc "`cancel_subscription`."
  @spec cancel(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cancel(id, params, opts),
    do:
      Client.run(Request.new(:cancel_subscription, :delete, ["subscriptions", id], params, opts))
end
