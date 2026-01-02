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

  alias Tymeslot.Infrastructure.CircuitBreaker
  require Logger

  @calendar_providers [:caldav, :radicale, :nextcloud, :google, :outlook]
  @calendar_breaker_names Enum.into(@calendar_providers, %{}, fn p ->
                            {p, :"calendar_breaker_#{p}"}
                          end)

  @default_config %{
    failure_threshold: 3,
    time_window: :timer.minutes(1),
    recovery_timeout: :timer.minutes(2),
    half_open_requests: 2
  }

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
  @spec call(atom(), (-> any())) :: {:ok, any()} | {:error, atom()}
  def call(provider, fun) when provider in @calendar_providers and is_function(fun, 0) do
    breaker_name = breaker_name(provider)

    # Circuit breakers are now started by the supervisor at application startup
    # Just check if it exists and log if it doesn't
    if breaker_exists?(breaker_name) do
      case CircuitBreaker.call(breaker_name, fun) do
        {:ok, result} ->
          {:ok, result}

        {:error, :circuit_open} = error ->
          Logger.warning("Calendar circuit breaker open", provider: provider)
          error

        {:error, reason} = error ->
          Logger.error("Calendar operation failed", provider: provider, error: inspect(reason))
          error
      end
    else
      Logger.error("Circuit breaker not found - it should be started by supervisor",
        provider: provider,
        breaker_name: breaker_name
      )

      # Fall back to direct execution without circuit breaker
      fun.()
    end
  rescue
    error ->
      Logger.error("Calendar circuit breaker error",
        provider: provider,
        error: inspect(error)
      )

      {:error, :circuit_breaker_error}
  end

  def call(provider, _fun) do
    {:error, {:invalid_provider, provider}}
  end

  @doc """
  Wraps a calendar operation with circuit breaker protection.

  This is a convenience function that handles common calendar operation patterns.
  """
  @spec with_breaker(atom(), keyword(), (-> any())) :: any()
  def with_breaker(provider, opts \\ [], fun) do
    skip_breaker = Keyword.get(opts, :skip_breaker, false)

    if skip_breaker do
      fun.()
    else
      call(provider, fun)
    end
  end

  @doc """
  Gets the status of a provider's circuit breaker.

  Returns :closed, :open, or :half_open.
  """
  @spec status(atom()) :: atom() | {:error, atom()}
  def status(provider) when provider in @calendar_providers do
    breaker_name = breaker_name(provider)

    if breaker_exists?(breaker_name) do
      CircuitBreaker.status(breaker_name)
    else
      # Default to closed if not started
      :closed
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

  defp breaker_exists?(name) do
    case Process.whereis(name) do
      nil -> false
      _pid -> true
    end
  end
end
