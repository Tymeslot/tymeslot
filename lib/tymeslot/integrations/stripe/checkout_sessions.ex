defmodule Tymeslot.Integrations.Stripe.CheckoutSessions do
  @moduledoc """
  Stripe `CheckoutSessions` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `create_checkout_session`, `retrieve_checkout_session`, `expire_checkout_session`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`create_checkout_session`."
  @spec create(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(params, opts),
    do:
      Client.run(
        Request.new(:create_checkout_session, :post, ["checkout", "sessions"], params, opts)
      )

  @doc "`retrieve_checkout_session`."
  @spec retrieve(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def retrieve(id, opts),
    do:
      Client.run(
        Request.new(:retrieve_checkout_session, :get, ["checkout", "sessions", id], %{}, opts)
      )

  @doc "`expire_checkout_session`."
  @spec expire(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def expire(id, opts),
    do:
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
