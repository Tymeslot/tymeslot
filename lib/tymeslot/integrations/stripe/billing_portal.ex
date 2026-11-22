defmodule Tymeslot.Integrations.Stripe.BillingPortal do
  @moduledoc """
  Stripe `BillingPortal` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `create_billing_portal_session`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`create_billing_portal_session`."
  @spec create_session(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_session(params, opts),
    do:
      Client.run(
        Request.new(
          :create_billing_portal_session,
          :post,
          ["billing_portal", "sessions"],
          params,
          opts
        )
      )
end
