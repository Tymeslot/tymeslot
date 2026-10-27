defmodule Tymeslot.Infrastructure.CircuitBreakerSupervisor do
  @moduledoc """
  Supervisor for circuit breakers used in the application.
  """

  use Supervisor

  alias Tymeslot.Infrastructure.ProviderBreakers

  @email_breaker_name :email_service_breaker

  @email_breaker_config %{
    failure_threshold: 3,
    time_window: :timer.minutes(1),
    recovery_timeout: :timer.minutes(5),
    half_open_requests: 2
  }

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Name of the breaker guarding the email provider."
  @spec email_breaker_name() :: atom()
  def email_breaker_name, do: @email_breaker_name

  @doc "The email breaker's configuration."
  @spec email_breaker_config() :: map()
  def email_breaker_config, do: @email_breaker_config

  @doc """
  How long the email breaker stays open before it probes the provider again.

  Exposed so callers that must outwait an open circuit (notably
  `Tymeslot.Workers.EmailWorker`, which snoozes rather than burning retries
  inside the window) derive the delay from the breaker's own tuning instead of
  repeating the number.
  """
  @spec email_breaker_recovery_seconds() :: pos_integer()
  def email_breaker_recovery_seconds,
    do: div(@email_breaker_config.recovery_timeout, 1_000)

  @impl Supervisor
  def init(_init_arg) do
    # Own the shared state table so its entries survive individual breaker GenServers
    # crashing and being restarted on the same BEAM. The table is lost only when this
    # supervisor exits (BEAM shutdown / full application restart) — not across deploys.
    if :ets.whereis(:circuit_breaker_state_table) == :undefined do
      :ets.new(:circuit_breaker_state_table, [:named_table, :public, :set])
    end

    # Dynamic supervisor for per-host circuit breakers
    dynamic_breakers = [
      {Registry, keys: :unique, name: Tymeslot.Infrastructure.CircuitBreakerRegistry},
      {DynamicSupervisor,
       name: Tymeslot.Infrastructure.DynamicCircuitBreakerSupervisor, strategy: :one_for_one}
    ]

    # Other circuit breakers
    other_breakers = [
      # Circuit breaker for email service (Postmark)
      Supervisor.child_spec(
        {Tymeslot.Infrastructure.CircuitBreaker,
         name: @email_breaker_name, config: @email_breaker_config},
        id: @email_breaker_name
      )
    ]

    children =
      ProviderBreakers.child_specs(:calendar) ++
        ProviderBreakers.child_specs(:video) ++ dynamic_breakers ++ other_breakers

    Supervisor.init(children, strategy: :one_for_one)
  end
end
