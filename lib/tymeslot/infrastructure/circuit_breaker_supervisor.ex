defmodule Tymeslot.Infrastructure.CircuitBreakerSupervisor do
  @moduledoc """
  Supervisor for circuit breakers used in the application.
  """

  use Supervisor

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig

  # Query providers with circuit breaker enabled from ProviderConfig
  @calendar_providers Enum.filter(
                        CalendarProviderConfig.all_providers(),
                        &CalendarProviderConfig.circuit_breaker_enabled?/1
                      )
  @calendar_breaker_names Enum.into(@calendar_providers, %{}, fn p ->
                            {p, :"calendar_breaker_#{p}"}
                          end)

  # Query video providers with circuit breaker enabled from ProviderConfig
  @video_providers Enum.filter(
                     VideoProviderConfig.all_providers(),
                     &VideoProviderConfig.circuit_breaker_enabled?/1
                   )
  @video_breaker_names Enum.into(@video_providers, %{}, fn p ->
                         {p, :"video_breaker_#{p}"}
                       end)

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
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
         name: :email_service_breaker,
         config: %{
           failure_threshold: 3,
           time_window: :timer.minutes(1),
           recovery_timeout: :timer.minutes(5),
           half_open_requests: 2
         }},
        id: :email_service_breaker
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
      ),
      Supervisor.child_spec(
        {Tymeslot.Infrastructure.CircuitBreaker,
         name: :oauth_oauth_breaker,
         config: %{
           failure_threshold: 3,
           time_window: :timer.minutes(2),
           recovery_timeout: :timer.minutes(5),
           half_open_requests: 1
         }},
        id: :oauth_oauth_breaker
      )
    ]

    children = calendar_breakers ++ video_breakers ++ dynamic_breakers ++ other_breakers

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_calendar_breakers do
    Enum.map(@calendar_providers, fn provider ->
      name = Map.fetch!(@calendar_breaker_names, provider)
      # Use configuration from CalendarCircuitBreaker to avoid duplication
      config = CalendarCircuitBreaker.get_config(provider)

      Supervisor.child_spec(
        {Tymeslot.Infrastructure.CircuitBreaker, name: name, config: config},
        id: name
      )
    end)
  end

  defp build_video_breakers do
    Enum.map(@video_providers, fn provider ->
      name = Map.fetch!(@video_breaker_names, provider)
      # Use configuration from VideoCircuitBreaker to avoid duplication
      config = VideoCircuitBreaker.get_config(provider)

      Supervisor.child_spec(
        {Tymeslot.Infrastructure.CircuitBreaker, name: name, config: config},
        id: name
      )
    end)
  end
end
