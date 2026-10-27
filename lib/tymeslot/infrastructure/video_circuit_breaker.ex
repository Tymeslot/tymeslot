defmodule Tymeslot.Infrastructure.VideoCircuitBreaker do
  @moduledoc """
  The video providers' circuit breakers: `ProviderBreakers` for the `:video`
  kind.

  Self-hosted providers (MiroTalk) route calls through a per-host breaker
  (see `ProviderAdapter.breaker_host/1`), so reading their health means
  passing the tenant's host to `status/2`.
  """

  alias Tymeslot.Infrastructure.ProviderBreakers

  @doc "See `ProviderBreakers.call/3`."
  @spec call(atom(), (-> any())) :: ProviderBreakers.result()
  def call(provider, fun), do: ProviderBreakers.call(:video, provider, fun)

  @doc "See `ProviderBreakers.call_with_host/4`."
  @spec call_with_host(atom(), String.t(), (-> any())) :: ProviderBreakers.result()
  def call_with_host(provider, host, fun),
    do: ProviderBreakers.call_with_host(:video, provider, host, fun)

  @doc "See `ProviderBreakers.with_breaker/4`."
  @spec with_breaker(atom(), keyword(), (-> any())) :: any()
  def with_breaker(provider, opts, fun),
    do: ProviderBreakers.with_breaker(:video, provider, opts, fun)

  @doc "See `ProviderBreakers.status/3`."
  @spec status(atom(), String.t() | nil) :: map() | {:error, term()}
  def status(provider, host \\ nil), do: ProviderBreakers.status(:video, provider, host)

  @doc "See `ProviderBreakers.reset/3`."
  @spec reset(atom(), String.t() | nil) :: :ok | {:error, term()}
  def reset(provider, host \\ nil), do: ProviderBreakers.reset(:video, provider, host)

  @doc "See `ProviderBreakers.config/2`."
  @spec get_config(atom()) :: map()
  def get_config(provider), do: ProviderBreakers.config(:video, provider)

  @doc """
  Longest `recovery_timeout` configured across every video provider's
  breaker, in seconds.

  `Tymeslot.Workers.VideoRoom.ErrorPolicy` snoozes an Oban job past
  `:circuit_open` rather than burning an attempt against a breaker known to
  be open, but by the time the error reaches it the reason has been reduced
  to a bare atom with no provider attached. Snoozing for the worst case
  across all providers is always long enough to clear whichever breaker
  actually tripped.
  """
  @spec max_recovery_seconds() :: pos_integer()
  def max_recovery_seconds do
    :video
    |> ProviderBreakers.providers()
    |> Enum.map(&get_config(&1).recovery_timeout)
    |> Enum.max()
    |> div(1_000)
  end
end
