defmodule Tymeslot.Infrastructure.CircuitBreakerSupervisor do
  @moduledoc """
  Supervisor for circuit breakers used in the application.
  """

  use Supervisor

  @calendar_providers [:caldav, :radicale, :nextcloud, :google, :outlook]
  @calendar_breaker_names Enum.into(@calendar_providers, %{}, fn p ->
                            {p, :"calendar_breaker_#{p}"}
                          end)

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Build children for all calendar providers
    calendar_breakers = build_calendar_breakers()

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
      )
    ]

    children = calendar_breakers ++ other_breakers

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_calendar_breakers do
    Enum.map(@calendar_providers, fn provider ->
      name = Map.fetch!(@calendar_breaker_names, provider)
      config = get_calendar_breaker_config(provider)

      Supervisor.child_spec(
        {Tymeslot.Infrastructure.CircuitBreaker, name: name, config: config},
        id: name
      )
    end)
  end

  defp get_calendar_breaker_config(:google) do
    %{
      failure_threshold: 5,
      time_window: :timer.minutes(1),
      recovery_timeout: :timer.minutes(5),
      half_open_requests: 2
    }
  end

  defp get_calendar_breaker_config(:outlook) do
    %{
      failure_threshold: 5,
      time_window: :timer.minutes(1),
      recovery_timeout: :timer.minutes(5),
      half_open_requests: 2
    }
  end

  defp get_calendar_breaker_config(:caldav) do
    %{
      failure_threshold: 3,
      time_window: :timer.minutes(1),
      recovery_timeout: :timer.minutes(2),
      half_open_requests: 2
    }
  end

  defp get_calendar_breaker_config(:radicale) do
    %{
      failure_threshold: 3,
      time_window: :timer.minutes(1),
      recovery_timeout: :timer.minutes(2),
      half_open_requests: 2
    }
  end

  defp get_calendar_breaker_config(:nextcloud) do
    %{
      failure_threshold: 4,
      time_window: :timer.minutes(1),
      recovery_timeout: :timer.minutes(3),
      half_open_requests: 2
    }
  end
end
