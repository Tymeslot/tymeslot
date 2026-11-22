defmodule Tymeslot.Integrations.Stripe.Charges do
  @moduledoc """
  Stripe `Charges` calls; return shape and options are described in
  `Tymeslot.Integrations.Stripe`.

  Operations, as named in telemetry and test stubs: `retrieve_charge`, `list_charges`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc """
  Retrieves a charge (GET /v1/charges/:id).
  """
  @spec retrieve(String.t(), keyword()) :: Client.result()
  def retrieve(id, opts \\ []) do
    Client.run(Request.new(:retrieve_charge, :get, ["charges", id], %{}, opts))
  end

  @doc """
  Lists charges (GET /v1/charges); `Pagination` walks all pages.
  """
  @spec list(map() | keyword(), keyword()) :: Client.result()
  def list(params, opts \\ []) do
    Client.run(Request.new(:list_charges, :get, ["charges"], params, opts))
  end
end
