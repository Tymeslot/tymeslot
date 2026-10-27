defmodule Tymeslot.Infrastructure.CalendarCircuitBreaker do
  @moduledoc """
  The calendar providers' circuit breakers: `ProviderBreakers` for the
  `:calendar` kind, plus `breaker_key/2`, which knows which breaker a
  calendar integration's calls trip.
  """

  alias Tymeslot.Infrastructure.ProviderBreakers
  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  # Self-hosted providers run every call through a breaker keyed by their
  # server's host (CalDAV events and discovery, the Exchange client); the
  # OAuth providers share the provider-level breaker.
  @host_keyed_providers ProviderConfig.caldav_based_providers() ++
                          ProviderConfig.ews_providers()

  @doc "See `ProviderBreakers.call/3`."
  @spec call(atom(), (-> any())) :: ProviderBreakers.result()
  def call(provider, fun), do: ProviderBreakers.call(:calendar, provider, fun)

  @doc "See `ProviderBreakers.call_with_host/4`."
  @spec call_with_host(atom(), String.t(), (-> any())) :: ProviderBreakers.result()
  def call_with_host(provider, host, fun),
    do: ProviderBreakers.call_with_host(:calendar, provider, host, fun)

  @doc "See `ProviderBreakers.with_breaker/4`."
  @spec with_breaker(atom(), keyword(), (-> any())) :: any()
  def with_breaker(provider, opts, fun),
    do: ProviderBreakers.with_breaker(:calendar, provider, opts, fun)

  @doc """
  The `{provider, host}` of the breaker that `provider`'s calls to `base_url`
  actually trip, to pass to `status/2` and `reset/2`.

  Self-hosted providers key it by their server's host, and by the provider
  their client carries, which is not always the integration's: a generic
  CalDAV client takes the server type detected from the URL
  (`CalDAV.Provider.client_provider/1`), so a `:caldav` integration at
  `/remote.php/dav` trips a `:nextcloud` breaker. Every other provider runs
  through its provider-level breaker, and gets a `nil` host.
  """
  @spec breaker_key(atom(), String.t() | nil) :: {atom(), String.t() | nil}
  def breaker_key(:caldav, base_url),
    do: {CalDAVProvider.client_provider(base_url), ProviderBreakers.host_from_base_url(base_url)}

  def breaker_key(provider, base_url) when provider in @host_keyed_providers,
    do: {provider, ProviderBreakers.host_from_base_url(base_url)}

  def breaker_key(provider, _base_url), do: {provider, nil}

  @doc "See `ProviderBreakers.status/3`; derive the arguments with `breaker_key/2`."
  @spec status(atom(), String.t() | nil) :: map() | {:error, term()}
  def status(provider, host \\ nil), do: ProviderBreakers.status(:calendar, provider, host)

  @doc "See `ProviderBreakers.reset/3`; derive the arguments with `breaker_key/2`."
  @spec reset(atom(), String.t() | nil) :: :ok | {:error, term()}
  def reset(provider, host \\ nil), do: ProviderBreakers.reset(:calendar, provider, host)

  @doc "See `ProviderBreakers.config/2`."
  @spec get_config(atom()) :: map()
  def get_config(provider), do: ProviderBreakers.config(:calendar, provider)
end
