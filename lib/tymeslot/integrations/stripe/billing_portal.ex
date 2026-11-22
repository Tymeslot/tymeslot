defmodule Tymeslot.Integrations.Stripe.BillingPortal do
  @moduledoc """
  Stripe `BillingPortal` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `create_billing_portal_session`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Creates a customer billing portal session (POST /v1/billing_portal/sessions).
  """
  @spec create_session(map() | keyword(), keyword()) :: Client.result()
  def create_session(params, opts \\ []) do
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
end
