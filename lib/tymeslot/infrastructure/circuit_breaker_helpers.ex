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
    * `:ok` - Function returned bare `:ok`
    * `{:ok, result}` - Function returned `{:ok, result}`
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
        ) :: :ok | {:ok, any()} | {:error, atom()}
  def call_with_breaker(breaker_name, provider, service_type, fun)
      when is_function(fun, 0) do
    if breaker_exists?(breaker_name) do
      case CircuitBreaker.call(breaker_name, fun) do
        :ok ->
          :ok

        {:ok, result} ->
          {:ok, result}

        {:error, :circuit_open} = error ->
          Logger.warning("Circuit breaker open", service: service_type, provider: provider)
          error

        {:provider_error, reason} ->
          Logger.error("Operation failed",
            service: service_type,
            provider: provider,
            error: inspect(reason)
          )

          {:error, reason}

        {:error, _reason, _message} = error ->
          Logger.error("Operation failed",
            service: service_type,
            provider: provider,
            error: inspect(error)
          )

          error

        {:error, reason} = error ->
          Logger.error("Operation failed",
            service: service_type,
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
      Logger.error("Circuit breaker error",
        service: service_type,
        provider: provider,
        error: inspect(error)
      )

      {:error, :circuit_breaker_error}
  catch
    # `breaker_exists?/1` and the subsequent `CircuitBreaker.call/3` are two
    # separate messages, so the breaker can stop (idle timeout, crash) in
    # between; `GenServer.call/3` then signals `:noproc`/`:timeout` as an
    # *exit*, which `rescue` cannot see.
    :exit, reason ->
      Logger.error("Circuit breaker error",
        service: service_type,
        provider: provider,
        error: inspect(reason)
      )

      {:error, :circuit_breaker_error}
  end

  @doc """
  Executes a function through a per-host circuit breaker, starting it
  dynamically if it doesn't exist yet.

  Shared by `CalendarCircuitBreaker.call_with_host/3` and
  `VideoCircuitBreaker.call_with_host/3`, which differ only in the
  breaker-id prefix, the logging label, and the provider's own config lookup.
  """
  @spec call_with_host_breaker(
          String.t(),
          atom(),
          String.t(),
          String.t(),
          map(),
          (-> any())
        ) :: :ok | {:ok, any()} | {:error, atom()}
  def call_with_host_breaker(prefix, provider, host, service_type, config, fun)
      when is_binary(prefix) and is_atom(provider) and is_binary(host) and is_function(fun, 0) do
    breaker_name = host_breaker_name(prefix, provider, host)
    ensure_host_breaker(breaker_name, config)

    case CircuitBreaker.call(breaker_name, fun) do
      :ok ->
        :ok

      {:ok, result} ->
        {:ok, result}

      {:error, :circuit_open} = error ->
        Logger.warning("Host circuit breaker open",
          service_type: service_type,
          provider: provider,
          host: host
        )

        error

      {:provider_error, reason} ->
        Logger.error("Host operation failed",
          service_type: service_type,
          provider: provider,
          host: host,
          error: inspect(reason)
        )

        {:error, reason}

      {:error, _reason, _message} = error ->
        Logger.error("Host operation failed",
          service_type: service_type,
          provider: provider,
          host: host,
          error: inspect(error)
        )

        error

      {:error, reason} = error ->
        Logger.error("Host operation failed",
          service_type: service_type,
          provider: provider,
          host: host,
          error: inspect(reason)
        )

        error
    end
  rescue
    error ->
      Logger.error("Host circuit breaker error",
        service_type: service_type,
        provider: provider,
        host: host,
        error: inspect(error)
      )

      {:error, :circuit_breaker_error}
  catch
    :exit, reason ->
      Logger.error("Host circuit breaker error",
        service_type: service_type,
        provider: provider,
        host: host,
        error: inspect(reason)
      )

      {:error, :circuit_breaker_error}
  end

  @doc """
  Builds the registered name (a Registry via-tuple) for a per-host circuit
  breaker. Public so callers that need to look up or reset a specific host's
  breaker — rather than run a function through it via `call_with_host_breaker/6` —
  can derive the same name without re-implementing the sanitisation.
  """
  @spec host_breaker_name(String.t(), atom(), String.t()) ::
          {:via, Registry, {module(), String.t()}}
  def host_breaker_name(prefix, provider, host) do
    safe_host = String.replace(host, ~r/[^a-zA-Z0-9]/, "_")
    breaker_id = "#{prefix}_#{provider}_#{safe_host}"
    {:via, Registry, {Tymeslot.Infrastructure.CircuitBreakerRegistry, breaker_id}}
  end

  @doc """
  Extracts the host from a self-hosted provider's `base_url`, for keying a
  per-host circuit breaker (see `host_breaker_name/3`). Returns `nil` when
  `base_url` is absent or unparseable — the caller then falls back to the
  provider-level breaker, which is what OAuth providers (no `base_url`) use.
  """
  @spec host_from_base_url(String.t() | nil) :: String.t() | nil
  def host_from_base_url(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> nil
    end
  end

  def host_from_base_url(_base_url), do: nil

  defp ensure_host_breaker(name, config) do
    unless breaker_exists?(name) do
      child_spec =
        {CircuitBreaker,
         name: name, config: config, idle_timeout: CircuitBreaker.default_idle_timeout()}

      DynamicSupervisor.start_child(
        Tymeslot.Infrastructure.DynamicCircuitBreakerSupervisor,
        child_spec
      )
    end
  end

  @doc """
  Checks if a circuit breaker process exists.

  Handles both direct process names and Registry-based via tuples.
  """
  @spec breaker_exists?(GenServer.server()) :: boolean()
  def breaker_exists?({:via, Registry, {registry, key}}) do
    case Registry.lookup(registry, key) do
      [{_pid, _value}] -> true
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
