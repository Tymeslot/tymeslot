defmodule Tymeslot.Integrations.Stripe.Disputes do
  @moduledoc """
  Stripe `Disputes` calls. Each function sends one request and returns
  `{:ok, map}` with Stripe's object string-keyed, or `{:error, reason}` as
  `Tymeslot.Integrations.Stripe.Client.run/1` does. `opts` are the request
  options (`:api_key`, `:connect_account`, `:idempotency_key` and the timeouts).

  Operations, as named in telemetry and test stubs: `list_disputes`.
  """

  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Request

  @doc "`list_disputes`."
  @spec list(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list(params, opts),
    do: Client.run(Request.new(:list_disputes, :get, ["disputes"], params, opts))
end
