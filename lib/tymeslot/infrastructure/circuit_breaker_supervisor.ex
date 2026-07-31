defmodule Tymeslot.Infrastructure.CircuitBreakerSupervisor do
  @moduledoc """
  Supervisor for circuit breakers used in the application.
  """

  use Supervisor

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig

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

    # Build children for all calendar providers
    calendar_breakers = build_calendar_breakers()

    # Build children for all video providers
    video_breakers = build_video_breakers()

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
      ),

      # Circuit breaker for OAuth services
      Supervisor.child_spec(
        {Tymeslot.Infrastructure.CircuitBreaker,
         name: :oauth_github_breaker,
         config: %{
           failure_threshold: 3,
           time_window: :timer.minutes(2),
           recovery_timeout: :timer.minutes(5),
           half_open_requests: 1
         }},
        id: :oauth_github_breaker
      ),
      Supervisor.child_spec(
        {Tymeslot.Infrastructure.CircuitBreaker,
         name: :oauth_google_breaker,
         config: %{
           failure_threshold: 3,
           time_window: :timer.minutes(2),
           recovery_timeout: :timer.minutes(5),
           half_open_requests: 1
         }},
        id: :oauth_google_breaker
      )
    ]

    children = calendar_breakers ++ video_breakers ++ dynamic_breakers ++ other_breakers

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_calendar_breakers do
    CalendarProviderConfig.all_providers()
    |> Enum.filter(&CalendarProviderConfig.circuit_breaker_enabled?/1)
    |> Enum.map(fn provider ->
      # provider comes from the fixed, compile-time-known provider list, so the
      # atom set is bounded — no unbounded-atom-creation risk here.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"calendar_breaker_#{provider}"
      config = CalendarCircuitBreaker.get_config(provider)

      Supervisor.child_spec({Tymeslot.Infrastructure.CircuitBreaker, name: name, config: config},
        id: name
      )
    end)
  end

  defp build_video_breakers do
    VideoProviderConfig.all_providers()
    |> Enum.filter(&VideoProviderConfig.circuit_breaker_enabled?/1)
    |> Enum.map(fn provider ->
      # provider comes from the fixed, compile-time-known provider list, so the
      # atom set is bounded — no unbounded-atom-creation risk here.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"video_breaker_#{provider}"
      config = VideoCircuitBreaker.get_config(provider)

      Supervisor.child_spec({Tymeslot.Infrastructure.CircuitBreaker, name: name, config: config},
        id: name
      )
    end)
  end
end
