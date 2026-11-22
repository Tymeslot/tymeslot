defmodule Tymeslot.Integrations.Stripe.Charges do
  @moduledoc """
  Stripe `Charges` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `retrieve_charge`, `list_charges`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`retrieve_charge`."
  @spec retrieve(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def retrieve(id, opts),
    do: Client.run(Request.new(:retrieve_charge, :get, ["charges", id], %{}, opts))

  @doc "`list_charges`."
  @spec list(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list(params, opts),
    do: Client.run(Request.new(:list_charges, :get, ["charges"], params, opts))
end
