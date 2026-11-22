defmodule Tymeslot.Integrations.Stripe.PaymentIntents do
  @moduledoc """
  Stripe `PaymentIntents` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `retrieve_payment_intent`, `create_payment_intent`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`retrieve_payment_intent`. `params` carry `expand`, for example `expand: [\"latest_charge\"]`."
  @spec retrieve(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def retrieve(id, params, opts),
    do:
      Client.run(
        Request.new(:retrieve_payment_intent, :get, ["payment_intents", id], params, opts)
      )

  @doc "`create_payment_intent`. No feature uses this yet; the live test suite does."
  @spec create(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(params, opts),
    do: Client.run(Request.new(:create_payment_intent, :post, ["payment_intents"], params, opts))
end
