defmodule Tymeslot.Integrations.Stripe.Refunds do
  @moduledoc """
  Stripe `Refunds` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `create_refund`, `list_refunds`, `retrieve_refund`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`create_refund`."
  @spec create(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(params, opts),
    do: Client.run(Request.new(:create_refund, :post, ["refunds"], params, opts))

  @doc "`list_refunds`."
  @spec list(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list(params, opts),
    do: Client.run(Request.new(:list_refunds, :get, ["refunds"], params, opts))

  @doc "`retrieve_refund`."
  @spec retrieve(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def retrieve(id, opts),
    do: Client.run(Request.new(:retrieve_refund, :get, ["refunds", id], %{}, opts))
end
