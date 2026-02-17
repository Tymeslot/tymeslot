defmodule Tymeslot.Infrastructure.CircuitBreakerHelpers do
  @moduledoc """
  Shared helper functions for circuit breaker wrappers.

  This module provides common logic for calendar and video circuit breaker
  implementations, reducing code duplication while maintaining type-specific
  logging and error handling.
  """

  alias Tymeslot.Infrastructure.CircuitBreaker
  require Logger

  @doc """
  Executes a function through a circuit breaker with logging and error handling.

  ## Parameters
    * `breaker_name` - The name or via tuple for the circuit breaker process
    * `provider` - The provider atom for logging context (e.g., :google, :caldav)
    * `service_type` - The service type string for logging (e.g., "Calendar", "Video")
    * `fun` - The zero-arity function to execute

  ## Returns
    * `{:ok, result}` - Function executed successfully
    * `{:error, :circuit_open}` - Circuit breaker is open
    * `{:error, :breaker_not_found}` - Circuit breaker process not found
    * `{:error, :circuit_breaker_error}` - Unexpected error during execution
    * `{:error, reason}` - Function failed with reason
  """
  @spec call_with_breaker(
          GenServer.server(),
          atom(),
          String.t(),
          (-> any())
        ) :: {:ok, any()} | {:error, atom()}
  def call_with_breaker(breaker_name, provider, service_type, fun)
      when is_function(fun, 0) do
    if breaker_exists?(breaker_name) do
      case CircuitBreaker.call(breaker_name, fun) do
        {:ok, result} ->
          {:ok, result}

        {:error, :circuit_open} = error ->
          Logger.warning("#{service_type} circuit breaker open", provider: provider)
          error

        {:error, reason} = error ->
          Logger.error("#{service_type} operation failed",
            provider: provider,
            error: inspect(reason)
          )

          error
      end
    else
      Logger.error("Circuit breaker not found - it should be started by supervisor",
        provider: provider,
        breaker_name: inspect(breaker_name)
      )

      {:error, :breaker_not_found}
    end
  rescue
    error ->
      Logger.error("#{service_type} circuit breaker error",
        provider: provider,
        error: inspect(error)
      )

      {:error, :circuit_breaker_error}
  end

  @doc """
  Checks if a circuit breaker process exists.

  Handles both direct process names and Registry-based via tuples.
  """
  @spec breaker_exists?(GenServer.server()) :: boolean()
  def breaker_exists?({:via, Registry, {registry, key}}) do
    case Registry.lookup(registry, key) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  def breaker_exists?(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> false
      _pid -> true
    end
  end
end
