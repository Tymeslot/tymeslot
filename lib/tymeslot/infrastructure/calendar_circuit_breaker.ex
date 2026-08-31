defmodule Tymeslot.Infrastructure.CalendarCircuitBreaker do
  @moduledoc """
  Circuit breaker implementation specifically for calendar provider integrations.

  This module wraps the generic CircuitBreaker with calendar-specific
  configuration and provider management.

  ## Features
  - Per-provider circuit breakers
  - Automatic circuit breaker registration
  - Calendar-specific error handling
  - Provider-aware configuration
  """

  alias Tymeslot.Infrastructure.{CircuitBreaker, CircuitBreakerHelpers}
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  require Logger

  @calendar_providers ProviderConfig.providers_with_circuit_breakers()
  @calendar_breaker_names Enum.into(@calendar_providers, %{}, fn p ->
                            {p, :"calendar_breaker_#{p}"}
                          end)

  @default_config %{
    failure_threshold: 3,
    time_window: :timer.minutes(1),
    recovery_timeout: :timer.minutes(2),
    half_open_requests: 2
  }

  # Circuit breaker configurations per calendar provider
  # - OAuth providers (Google, Outlook): More lenient due to rate limiting and API quotas
  # - Self-hosted CalDAV (CalDAV, Radicale, Zimbra): Standard settings for typical self-hosted servers
  # - Nextcloud: Slightly more lenient than basic CalDAV due to heavier server operations
  # - mailbox.org (Open-Xchange): Same conservative defaults as other CalDAV providers
  @provider_configs %{
    google: %{
      failure_threshold: 5,
      recovery_timeout: :timer.minutes(5)
    },
    outlook: %{
      failure_threshold: 5,
      recovery_timeout: :timer.minutes(5)
    },
    caldav: %{
      failure_threshold: 3,
      recovery_timeout: :timer.minutes(2)
    },
    radicale: %{
      failure_threshold: 3,
      recovery_timeout: :timer.minutes(2)
    },
    nextcloud: %{
      failure_threshold: 4,
      recovery_timeout: :timer.minutes(3)
    },
    zimbra: %{
      failure_threshold: 3,
      recovery_timeout: :timer.minutes(2)
    },
    mailbox_org: %{
      failure_threshold: 3,
      recovery_timeout: :timer.minutes(2)
    },
    apple: %{
      failure_threshold: 3,
      recovery_timeout: :timer.minutes(2)
    }
  }

  @doc """
  Executes a calendar operation through the circuit breaker for the given provider.

  ## Examples

      iex> CalendarCircuitBreaker.call(:google, fn ->
      ...>   # Perform Google Calendar API call
      ...>   {:ok, events}
      ...> end)
      {:ok, events}

      iex> CalendarCircuitBreaker.call(:caldav, fn ->
      ...>   # Circuit open due to failures
      ...> end)
      {:error, :circuit_open}
  """
  @spec call(atom(), (-> any())) :: CircuitBreakerHelpers.result()
  def call(provider, fun) when provider in @calendar_providers and is_function(fun, 0) do
    breaker_name = breaker_name(provider)
    CircuitBreakerHelpers.call_with_breaker(breaker_name, provider, "Calendar", fun)
  end

  def call(provider, _fun) do
    {:error, {:invalid_provider, provider}}
  end

  @doc """
  Executes a calendar operation through a host-specific circuit breaker.
  Useful for CalDAV providers where individual servers may be slow or down.
  """
  @spec call_with_host(atom(), String.t(), (-> any())) :: CircuitBreakerHelpers.result()
  def call_with_host(provider, host, fun)
      when is_atom(provider) and is_binary(host) and is_function(fun, 0) do
    CircuitBreakerHelpers.call_with_host_breaker(
      "calendar_breaker",
      provider,
      host,
      "Calendar",
      get_config(provider),
      fun
    )
  end

  @doc """
  Wraps a calendar operation with circuit breaker protection.

  This is a convenience function that handles common calendar operation patterns.
  """
  @spec with_breaker(atom(), keyword(), (-> any())) :: any()
  def with_breaker(provider, opts \\ [], fun) do
    skip_breaker = Keyword.get(opts, :skip_breaker, false)
    host = Keyword.get(opts, :host)

    cond do
      skip_breaker ->
        fun.()

      is_binary(host) and host != "" ->
        call_with_host(provider, host, fun)

      true ->
        call(provider, fun)
    end
  end

  @doc """
  Gets the status of a provider's circuit breaker.

  Returns :closed, :open, or :half_open.
  """
  @spec status(atom()) :: map() | {:error, atom()} | {:error, {:invalid_provider, atom()}}
  def status(provider) when provider in @calendar_providers do
    breaker_name = breaker_name(provider)

    if breaker_exists?(breaker_name) do
      CircuitBreaker.status(breaker_name)
    else
      # Return error instead of hiding the fact that breaker doesn't exist
      {:error, :breaker_not_found}
    end
  end

  def status(provider) do
    {:error, {:invalid_provider, provider}}
  end

  @doc """
  Resets a provider's circuit breaker to closed state.

  Useful for manual recovery or testing.
  """
  @spec reset(atom()) :: :ok | {:error, atom()}
  def reset(provider) when provider in @calendar_providers do
    breaker_name = breaker_name(provider)

    if breaker_exists?(breaker_name) do
      CircuitBreaker.reset(breaker_name)
      Logger.info("Calendar circuit breaker reset", provider: provider)
      :ok
    else
      {:error, :breaker_not_found}
    end
  end

  def reset(provider) do
    {:error, {:invalid_provider, provider}}
  end

  @doc """
  Resets the host-specific circuit breaker for a provider and URL.

  A successful reconnect to a host that was previously failing should clear the
  breaker so the next operation isn't rejected immediately with `:circuit_open`.
  Returns `:ok` even if no host breaker exists yet (idempotent).
  """
  @spec reset_for_url(atom(), String.t()) :: :ok
  def reset_for_url(provider, url) when provider in @calendar_providers and is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        safe_host = String.replace(host, ~r/[^a-zA-Z0-9]/, "_")
        breaker_id = "calendar_breaker_#{provider}_#{safe_host}"

        breaker_name =
          {:via, Registry, {Tymeslot.Infrastructure.CircuitBreakerRegistry, breaker_id}}

        if breaker_exists?(breaker_name) do
          CircuitBreaker.reset(breaker_name)
          Logger.info("Calendar host circuit breaker reset", provider: provider, host: host)
        end

        :ok

      _other ->
        :ok
    end
  end

  def reset_for_url(_provider, _url), do: :ok

  @doc """
  Resets every host-keyed calendar circuit breaker.

  `reset/1` only covers the named provider-level breakers; host breakers are
  registered dynamically per host and would otherwise retain their failure
  counts. Primarily used by tests, where breaker state must not leak between
  cases.
  """
  @spec reset_all_hosts() :: :ok
  def reset_all_hosts do
    Tymeslot.Infrastructure.DynamicCircuitBreakerSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> reset_by_pid(pid)
      _other -> :ok
    end)

    :ok
  end

  # `CircuitBreaker.reset/1`'s ETS clear is keyed by the breaker's registered
  # name (its via-tuple), never a pid — resolve the pid back to the key(s) it
  # is registered under before resetting, otherwise the ETS delete targets a
  # key that was never inserted and a stale `:open` snapshot survives.
  defp reset_by_pid(pid) do
    Tymeslot.Infrastructure.CircuitBreakerRegistry
    |> Registry.keys(pid)
    |> Enum.each(fn key ->
      CircuitBreaker.reset(
        {:via, Registry, {Tymeslot.Infrastructure.CircuitBreakerRegistry, key}}
      )
    end)
  end

  @doc """
  Gets the configuration for a specific provider.
  """
  @spec get_config(atom()) :: map()
  def get_config(provider) do
    provider_specific = Map.get(@provider_configs, provider, %{})
    Map.merge(@default_config, provider_specific)
  end

  # Private functions

  defp breaker_name(provider) do
    Map.fetch!(@calendar_breaker_names, provider)
  end

  defp breaker_exists?(name), do: CircuitBreakerHelpers.breaker_exists?(name)
end
