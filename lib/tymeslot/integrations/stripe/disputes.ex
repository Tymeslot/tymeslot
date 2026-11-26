defmodule Tymeslot.Integrations.Stripe.Disputes do
  @moduledoc """
  Stripe `Disputes` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `list_disputes`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Lists disputes (GET /v1/disputes); `Pagination` walks all pages.
  """
  @spec list(map() | keyword(), keyword()) :: Client.result()
  def list(params, opts \\ []) do
    Client.run(Request.new(:list_disputes, :get, ["disputes"], params, opts))
  end
end
