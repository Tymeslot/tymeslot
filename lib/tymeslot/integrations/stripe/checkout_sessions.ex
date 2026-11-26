defmodule Tymeslot.Integrations.Stripe.CheckoutSessions do
  @moduledoc """
  Stripe `CheckoutSessions` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `create_checkout_session`, `retrieve_checkout_session`, `expire_checkout_session`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Creates a Checkout session (POST /v1/checkout/sessions). Connect sessions pass `connect_account:`.
  """
  @spec create(map() | keyword(), keyword()) :: Client.result()
  def create(params, opts \\ []) do
    Client.run(
      Request.new(:create_checkout_session, :post, ["checkout", "sessions"], params, opts)
    )
  end

  @doc """
  Retrieves a Checkout session (GET /v1/checkout/sessions/:id).
  """
  @spec retrieve(String.t(), keyword()) :: Client.result()
  def retrieve(id, opts \\ []) do
    Client.run(
      Request.new(:retrieve_checkout_session, :get, ["checkout", "sessions", id], %{}, opts)
    )
  end

  @doc """
  Expires an open Checkout session (POST /v1/checkout/sessions/:id/expire).
  """
  @spec expire(String.t(), keyword()) :: Client.result()
  def expire(id, opts \\ []) do
    Client.run(
      Request.new(
        :expire_checkout_session,
        :post,
        ["checkout", "sessions", id, "expire"],
        %{},
        opts
      )
    )
  end
end
