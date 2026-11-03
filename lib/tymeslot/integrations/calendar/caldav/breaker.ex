defmodule Tymeslot.Integrations.Calendar.CalDAV.Breaker do
  @moduledoc """
  The circuit breaker every CalDAV event read and write runs under.

  A CalDAV breaker is keyed by the provider the client carries and by the
  host of its server, so one self-hosted server failing never opens the
  breaker for every other server of the same kind. `CalDAV.Discovery` keeps
  its own wrapper, since it also honours the client's `:skip_breaker` and
  re-raises a breaker exit.
  """

  alias Tymeslot.Infrastructure.{CalendarCircuitBreaker, ProviderBreakers}
  alias Tymeslot.Integrations.Calendar.CalDAV.Base

  @doc """
  Runs `fun` under the breaker for `client`'s provider and server host,
  passing `opts` on to `CalendarCircuitBreaker.with_breaker/3`.
  """
  @spec run(Base.client(), keyword(), (-> any())) :: any()
  def run(client, opts, fun) when is_function(fun, 0) do
    provider = Map.get(client, :provider, :caldav)
    opts = Keyword.put(opts, :host, ProviderBreakers.host_from_base_url(client.base_url))
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end
end
