defmodule Tymeslot.Integrations.Stripe.PaymentIntents do
  @moduledoc """
  Stripe `PaymentIntents` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `retrieve_payment_intent`, `create_payment_intent`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Retrieves a payment intent (GET /v1/payment_intents/:id). `params` carry `expand`, for example `expand: ["latest_charge"]`.
  """
  @spec retrieve(String.t(), map() | keyword(), keyword()) :: Client.result()
  def retrieve(id, params, opts \\ []) do
    Client.run(Request.new(:retrieve_payment_intent, :get, ["payment_intents", id], params, opts))
  end

  @doc """
  Creates a payment intent (POST /v1/payment_intents). No feature uses this yet; the live test suite does.
  """
  @spec create(map() | keyword(), keyword()) :: Client.result()
  def create(params, opts \\ []) do
    Client.run(Request.new(:create_payment_intent, :post, ["payment_intents"], params, opts))
  end
end
