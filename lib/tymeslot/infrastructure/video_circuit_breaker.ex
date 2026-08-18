defmodule Tymeslot.Infrastructure.VideoCircuitBreaker do
  @moduledoc """
  Circuit breaker implementation specifically for video provider integrations.

  This module wraps the generic CircuitBreaker with video-specific
  configuration and provider management.

  ## Features
  - Per-provider circuit breakers
  - Automatic circuit breaker registration
  - Video-specific error handling
  - Provider-aware configuration
  """

  alias Tymeslot.Infrastructure.{CircuitBreaker, CircuitBreakerHelpers}
  alias Tymeslot.Integrations.Video.ProviderConfig
  require Logger

  # Query providers with circuit breaker enabled from ProviderConfig
  @video_providers Enum.filter(
                     ProviderConfig.all_providers(),
                     &ProviderConfig.circuit_breaker_enabled?/1
                   )
  @video_breaker_names Enum.into(@video_providers, %{}, fn p ->
                         {p, :"video_breaker_#{p}"}
                       end)

  @default_config %{
    failure_threshold: 3,
    time_window: :timer.minutes(1),
    recovery_timeout: :timer.minutes(2),
    half_open_requests: 2
  }

  @provider_configs %{
    google_meet: %{
      failure_threshold: 5,
      recovery_timeout: :timer.minutes(5)
    },
    teams: %{
      failure_threshold: 5,
      recovery_timeout: :timer.minutes(5)
    },
    mirotalk: %{
      failure_threshold: 3,
      recovery_timeout: :timer.minutes(2)
    }
  }

  @doc """
  Executes a video operation through the circuit breaker for the given provider.

  ## Examples

      iex> VideoCircuitBreaker.call(:google_meet, fn ->
      ...>   # Perform Google Meet API call
      ...>   {:ok, room}
      ...> end)
      {:ok, room}

      iex> VideoCircuitBreaker.call(:teams, fn ->
      ...>   # Circuit open due to failures
      ...> end)
      {:error, :circuit_open}
  """
  @spec call(atom(), (-> any())) :: :ok | {:ok, any()} | {:error, atom()}
  def call(provider, fun) when provider in @video_providers and is_function(fun, 0) do
    breaker_name = breaker_name(provider)
    CircuitBreakerHelpers.call_with_breaker(breaker_name, provider, "Video", fun)
  end

  def call(provider, _fun) do
    {:error, {:invalid_provider, provider}}
  end

  @doc """
  Gets the status of a provider's circuit breaker.

  Returns :closed, :open, or :half_open.
  """
  @spec status(atom()) :: map() | {:error, atom()} | {:error, {:invalid_provider, atom()}}
  def status(provider) when provider in @video_providers do
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
  def reset(provider) when provider in @video_providers do
    breaker_name = breaker_name(provider)

    if breaker_exists?(breaker_name) do
      CircuitBreaker.reset(breaker_name)
      Logger.info("Video circuit breaker reset", provider: provider)
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
    @video_providers
    |> Enum.map(&get_config/1)
    |> Enum.map(& &1.recovery_timeout)
    |> Enum.max()
    |> div(1_000)
  end

  # Private functions

  defp breaker_name(provider) do
    Map.fetch!(@video_breaker_names, provider)
  end

  defp breaker_exists?(name), do: CircuitBreakerHelpers.breaker_exists?(name)
end
