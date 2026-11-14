defmodule Tymeslot.EmailSending.Breakers do
  @moduledoc """
  Independently guards each revision of an owner's SMTP account.

  Accounts on the same relay must not share authentication failures. Registry
  tuples avoid user-derived atoms, and the existing dynamic breaker lifecycle
  expires idle revisions while preserving crash recovery on the running node.
  Recovery timing matches the platform email breaker and existing Oban snoozes.
  """

  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.Infrastructure.{CircuitBreaker, CircuitBreakerSupervisor}

  require Logger

  @registry Tymeslot.Infrastructure.CircuitBreakerRegistry
  @supervisor Tymeslot.Infrastructure.DynamicCircuitBreakerSupervisor

  @doc "The Registry name for a specific owner, settings record, and revision."
  @spec name(Sender.t()) :: GenServer.name()
  def name(%Sender{owner_id: owner_id, settings_id: settings_id, revision: revision}) do
    {:via, Registry, {@registry, {:user_smtp, owner_id, settings_id, revision}}}
  end

  @doc "Runs a send through the account's own lazily started circuit breaker."
  @spec call(Sender.t(), (-> CircuitBreaker.result()), keyword()) :: CircuitBreaker.result()
  def call(%Sender{kind: :user_smtp} = sender, fun, opts) when is_function(fun, 0) do
    with :ok <- ensure_started(sender) do
      CircuitBreaker.call(name(sender), fun, opts)
    end
  rescue
    # Registry lookup can raise while its supervisor is restarting. Keep a
    # short refusal, without exposing any account details from the callback.
    _error ->
      Logger.warning("User SMTP circuit breaker unavailable")
      {:error, :breaker_unavailable}
  catch
    # A breaker can expire between lazy startup and the permission request.
    # A retry recreates it; falling back to the platform breaker is unsafe.
    :exit, _reason ->
      Logger.warning("User SMTP circuit breaker terminated")
      {:error, :breaker_unavailable}
  end

  defp ensure_started(sender) do
    breaker = name(sender)

    if registered?(breaker) do
      :ok
    else
      case DynamicSupervisor.start_child(
             @supervisor,
             {CircuitBreaker,
              name: breaker,
              config: CircuitBreakerSupervisor.email_breaker_config(),
              idle_timeout: CircuitBreaker.default_idle_timeout()}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        _unavailable -> {:error, :breaker_unavailable}
      end
    end
  end

  defp registered?({:via, Registry, {registry, key}}), do: Registry.lookup(registry, key) != []
end
